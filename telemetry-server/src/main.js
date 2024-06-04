require('dotenv').config()
const { meterProvider } = require('./meterProvider')
const { listenForGatewayData } = require('./gatewayDataReceiver')

const GATEWAY_PORT = process.env.GATEWAY_PORT || 5000

const meter = meterProvider.getMeter('main')

// Now, start recording data
const counter = meter.createCounter('metric_name', {
  description: 'Example of a counter',
})

listenForGatewayData(GATEWAY_PORT)
console.log('Press Ctrl+C to stop')

setInterval(() => counter.add(10, { pid: process.pid }), 1000)
