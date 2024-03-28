return {
  { name = "core", namespace = "kong.components.datastore.migrations.core", },
  { name = "*plugins", namespace = "kong.plugins.*.migrations", name_pattern = "%s" },
}
