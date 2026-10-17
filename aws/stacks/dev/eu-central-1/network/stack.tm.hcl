stack {
  name        = "network"
  description = "VPC with public and private subnets in the zones listed in azs"
  after       = ["../state-backend"]
}
