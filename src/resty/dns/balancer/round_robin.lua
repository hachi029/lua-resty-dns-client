--------------------------------------------------------------------------
-- Round-Robin balancer
--
-- @author Vinicius Mignot
-- @copyright 2021 Kong Inc. All rights reserved.
-- @license Apache 2.0


local balancer_base = require "resty.dns.balancer.base"

local ngx_log = ngx.log
local ngx_DEBUG = ngx.DEBUG
local random = math.random

local MAX_WHEEL_SIZE = 2^32


local _M = {}
local roundrobin_balancer = {}


-- calculate the greater common divisor, used to find the smallest wheel
-- possible
local function gcd(a, b)
  if b == 0 then
    return a
  end

  return gcd(b, a % b)
end


local function wheel_shuffle(wheel)
  for i = #wheel, 2, -1 do
    local j = random(i)
    wheel[i], wheel[j] = wheel[j], wheel[i]
  end
  return wheel
end


function roundrobin_balancer:afterHostUpdate(host)
  local new_wheel = {}    --每次host变更，重新构建wheel
  local total_points = 0
  local total_weight = 0
  local addr_count = 0
  local divisor = 0

  -- calculate the gcd to find the proportional weight of each address
  for _, host in ipairs(self.hosts) do        --- 遍历每个host
    for _, address in ipairs(host.addresses) do   --- 对于host的每个address
      addr_count = addr_count + 1
      local address_weight = address.weight
      divisor = gcd(divisor, address_weight)      --计算最大公约数
      total_weight = total_weight + address_weight
    end
  end

  if total_weight == 0 then
    ngx_log(ngx_DEBUG, self.log_prefix, "trying to set a round-robin balancer with no addresses")
    return
  end

  --- 例如 10 30 50 ， total_weight = 90, total_points=9 , 每个address的points = 1, 3, 5
  if divisor > 0 then     --- total_points = 所有weight之和/所有weight最大公约数
    total_points = total_weight / divisor
  end

  -- add all addresses to the wheel
  for _, host in ipairs(self.hosts) do
    for _, address in ipairs(host.addresses) do
      local address_points = address.weight / divisor     ---计算每个address的points
      for _ = 1, address_points do                        --- 在new_wheel中相应地有points个point
        new_wheel[#new_wheel + 1] = address
      end
    end
  end

  -- store the shuffled wheel
  self.wheel = wheel_shuffle(new_wheel)   --- 打乱顺序
  self.wheelSize = total_points
  self.weight = total_weight

end

--- 关键结构：self.wheel : {add1, add2, add1, add2, add3}   按address权重创建的address数组
--- self.wheelSize wheel数组长度
--- self.pointer 一个wheel的索引指针。
--- 算法：根据权重计算wheel数组里每个address应该放置的个数.(total_weight/divisor)，然后将wheel数组随机打乱
---      每次getPeer时，从self.pointer开始，依次取address
function roundrobin_balancer:getPeer(cacheOnly, handle, hashValue)
  if not self.healthy then    --- 1. 当前balancer已不健康（不健康实例占比超过阈值）
    return nil, balancer_base.errors.ERR_BALANCER_UNHEALTHY
  end

  if handle then    --- handler是一个上下文
    -- existing handle, so it's a retry
    handle.retryCount = handle.retryCount + 1
  else
    -- no handle, so this is a first try
    handle = self:getHandle()  -- no GC specific handler needed
    handle.retryCount = 0
  end

  local starting_pointer = self.pointer   --- 从上次结束的位置开始
  local address
  local ip, port, hostname
  repeat
    self.pointer = self.pointer + 1

    if self.pointer > self.wheelSize then
      self.pointer = 1
    end

    address = self.wheel[self.pointer]
    --- 如果当前address健康，且未被disabled
    if address ~= nil and address.available and not address.disabled then
      ip, port, hostname = address:getPeer(cacheOnly)
      if ip then
        -- success, update handle
        handle.address = address
        return ip, port, hostname, handle

      elseif port == balancer_base.errors.ERR_DNS_UPDATED then
        -- if healty we just need to try again
        if not self.healthy then
          return nil, balancer_base.errors.ERR_BALANCER_UNHEALTHY
        end
      elseif port == balancer_base.errors.ERR_ADDRESS_UNAVAILABLE then
        ngx_log(ngx_DEBUG, self.log_prefix, "found address but it was unavailable. ",
                " trying next one.")
      else
        -- an unknown error occured
        return nil, port
      end

    end

  until self.pointer == starting_pointer

  return nil, balancer_base.errors.ERR_NO_PEERS_AVAILABLE
end

--- 1. 创建balancer_base
--- 2. 执行balancer_base.addHost
function _M.new(opts)
  assert(type(opts) == "table", "Expected an options table, but got: "..type(opts))
  if not opts.log_prefix then
    opts.log_prefix = "round-robin"
  end

  local self = assert(balancer_base.new(opts))

  for name, method in pairs(roundrobin_balancer) do
    self[name] = method
  end

  -- inject additional properties
  self.pointer = 1 -- pointer to next-up index for the round robin scheme
  self.wheelSize = 0
  self.maxWheelSize = opts.maxWheelSize or opts.wheelSize or MAX_WHEEL_SIZE
  self.wheel = {}

  -- addHost
  for _, host in ipairs(opts.hosts or {}) do
    local new_host = type(host) == "table" and host or { name = host }
    local ok, err = self:addHost(new_host.name, new_host.port, new_host.weight)
    if not ok then
      return ok, "Failed creating a balancer: " .. tostring(err)
    end
  end

  ngx_log(ngx_DEBUG, self.log_prefix, "round_robin balancer created")

  return self

end

return _M
