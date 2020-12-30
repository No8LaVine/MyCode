---
--- Generated by Luanalysis
--- Created by THUNDER.
--- DateTime: 2020/11/6 11:18
---
--- evalsha shaname keynum [k1...kn] [arg1...argn]
local key = KEYS[1]
local limit = tonumber(ARGV[1])
local expire_time = ARGV[2]

local current = tonumber(redis.call('get', key) or "0")
if current > 0 then
    if current + 1 > limit then
        return 0
    else
        redis.call("INCR", key)
        return 1
    end
else
    redis.call("SET", key, 1)
    redis.call("EXPIRE", key, expire_time)
    return 1
end