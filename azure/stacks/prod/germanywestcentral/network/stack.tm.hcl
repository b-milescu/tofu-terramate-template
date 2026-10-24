stack {
  name        = "network"
  description = "Virtual network with private subnets behind one network security group"
  after       = ["../state-backend"]
}
