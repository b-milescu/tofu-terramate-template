stack {
  name        = "network"
  description = "Custom-mode VPC network with one private subnetwork, flow logs and Private Google Access"
  after       = ["../state-backend"]
}
