locals {
  iam_module_version = "v6.8.0"
}

terraform {
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-iam.git//modules/iam-group?ref=${local.iam_module_version}"
}

inputs = {
  name = "production-admins"
}