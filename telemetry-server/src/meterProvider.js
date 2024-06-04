require('dotenv').config()
const { MeterProvider } = require('@opentelemetry/sdk-metrics')
const { PrometheusExporter } = require('@opentelemetry/exporter-prometheus')

const PROMETHEUS_PORT = process.env.PROMETHEUS_PORT || 9464

const meterProvider = new MeterProvider()
const exporter = new PrometheusExporter({ port: PROMETHEUS_PORT })
console.log(`Prometheus server running on port ${PROMETHEUS_PORT}`)

meterProvider.addMetricReader(exporter)

module.exports = { meterProvider }
