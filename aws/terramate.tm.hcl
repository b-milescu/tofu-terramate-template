# Terramate project settings. Terramate treats the git root as the project root and ignores these root-only
# settings anywhere else, so this file stays at the top of the repository.
terramate {
  required_version = "~> 0.17.3"

  config {
    telemetry {
      enabled = false
    }
  }
}
