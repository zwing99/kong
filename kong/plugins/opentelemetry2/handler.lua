local kong = kong
local kong_meta = require "kong.meta"
local Queue = require "kong.tools.queue"
local cjson = require "cjson"

local Opentelemetry2Handler = {
  PRIORITY = 13,
  VERSION = kong_meta.version,
}

local queue_conf = -- configuration for the queue itself (defaults shown unless noted)
{
  name = "opentelemetry", -- name of the queue (required)
  log_tag = "opentelemetry", -- tag string to identify plugin or application area in logs
  max_batch_size = 1000, -- maximum number of entries in one batch (default 1)
  max_coalescing_delay = 1, -- maximum number of seconds after first entry before a batch is sent
  max_entries = 10000, -- maximum number of entries on the queue (default 10000)
  max_bytes = nil, -- maximum number of bytes on the queue (default nil)
  initial_retry_delay = 0.01, -- initial delay when retrying a failed batch, doubled for each subsequent retry
  max_retry_time = 60, -- maximum number of seconds before a failed batch is dropped
  max_retry_delay = 60, -- maximum delay between send attempts, caps exponential retry
}

local METRICS_PROCESSOR_HOST = '127.0.0.1'
local METRICS_PROCESSOR_PORT = 5000

local function send_message(_conf, entries)
  local sock = ngx.socket.tcp()

  local ok, err = sock:connect(METRICS_PROCESSOR_HOST, METRICS_PROCESSOR_PORT)
  if not ok then
    kong.log.err("failed to connect to ", host, ":", tostring(port), ": ", err)
    sock:close()
    return false
  end

  ok, err = sock:send(entries)
  if not ok then
    kong.log.err("failed to send data to ", host, ":", tostring(port), ": ", err)
    sock:close()
    return false
  end

  ok, err = sock:setkeepalive(1)
  if not ok then
    kong.log.err("failed to keepalive to ", host, ":", tostring(port), ": ", err)
    sock:close()
  end

  return true
end

local function enqueue_message(type, data)
  Queue.enqueue(queue_conf, send_message, null, cjson.encode({ type = type, data = data }) .. "\n")
end

function Opentelemetry2Handler:configure(configs)
  enqueue_message("configure", configs)
end

local http_subsystem = ngx.config.subsystem == "http"

function Opentelemetry2Handler:log(conf)
  local message = kong.log.serialize()

  local serialized = {}
  if conf.per_consumer and message.consumer ~= nil then
    serialized.consumer = message.consumer.username
  end

  if conf.status_code_metrics then
    if http_subsystem and message.response then
      serialized.status_code = message.response.status
    elseif not http_subsystem and message.session then
      serialized.status_code = message.session.status
    end
  end

  if conf.bandwidth_metrics then
    if http_subsystem then
      serialized.egress_size = message.response and tonumber(message.response.size)
      serialized.ingress_size = message.request and tonumber(message.request.size)
    else
      serialized.egress_size = message.response and tonumber(message.session.sent)
      serialized.ingress_size = message.request and tonumber(message.session.received)
    end
  end

  if conf.latency_metrics then
    serialized.latencies = message.latencies
  end

  enqueue_message("log", serialized)
end

return Opentelemetry2Handler
