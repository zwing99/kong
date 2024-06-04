const net = require('net')

const { meterProvider } = require('./meterProvider')

const meter = meterProvider.getMeter('gatewayDataReceiver')
const connectionCounter = meter.createCounter('gateway_total_connections', {
  description: 'Total number of connections to the gateway data server',
})
const connectionGauge = meter.createGauge('gateway_current_connections', {
  description: 'Current number of connections to the gateway data server',
})
const messagesProcessed = meter.createCounter('gateway_messages_processed', {
  description: 'Total number of messages processed by the gateway data server',
})
const messagesFailed = meter.createCounter('gateway_messages_failed', {
  description:
    'Total number of messages failed to be processed by the gateway data server',
})

const percentiles = [0.5, 0.9, 0.95, 0.99, 0.99]
const upstreamLatencies = meter.createHistogram('upstream_latency', {
  boundaries: percentiles,
  description: 'Latency of requests to the upstream service',
})
const kongLatencies = meter.createHistogram('kong_latency', {
  boundaries: percentiles,
  description: 'Latency of requests inside of Kong',
})
const requestLatencies = meter.createHistogram('request_latency', {
  boundaries: percentiles,
  description: 'Latency of requests, including Kong and upstream service',
})

const extractRequestMetrics = (message) => {
  const { service, route, latencies, response } = message
  const { status } = response || {}
  const attributes = {
    service: service.name || service.id,
    route: route.name || route.id,
    status,
  }
  if (latencies.kong) {
    kongLatencies.record(latencies.kong, {})
    kongLatencies.record(latencies.kong, attributes)
  }
  if (latencies.request) {
    requestLatencies.record(latencies.request, {})
    requestLatencies.record(latencies.request, attributes)
  }
}

const handleMessage = (message) => {
  messagesProcessed.add(1)
  switch (message.type) {
    case 'log':
      extractRequestMetrics(message.data)
      break
    case 'configure':
      console.log('Received config:', message.data)
      break
    default:
      console.log('Unknown message type:', message.type)
      break
  }
}

const listenForGatewayData = (port) => {
  let connectionCount = 0
  const server = net.createServer((socket) => {
    connectionCounter.add(1)
    connectionGauge.record(++connectionCount)

    let buffer = ''

    // When data is received from the client
    socket.on('data', (data) => {
      buffer += data

      let lineEndIndex = buffer.indexOf('\n')
      while (lineEndIndex !== -1) {
        const line = buffer.substring(0, lineEndIndex)
        buffer = buffer.substring(lineEndIndex + 1)

        try {
          const message = JSON.parse(line)

          handleMessage(message)
        } catch (error) {
          console.error('Error handling message:', error)
          messagesFailed.add(1)
        }

        lineEndIndex = buffer.indexOf('\n')
      }
    })

    // When the client disconnects
    socket.on('end', () => {
      connectionGauge.record(--connectionCount)
    })
  })

  // Start the server
  server.listen(port, () => {
    console.log(`Gateway data server listening on port ${port}`)
  })
}

module.exports = { listenForGatewayData }
