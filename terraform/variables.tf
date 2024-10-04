variable "env" {
  type    = string
  default = "ce6final"
}

variable "aliases" {
  type        = list(any)
  description = "Alternate domain names"
  default     = []
}

# variables.tf
variable "acm_certificate_arn" {
  description = "ACM certificate ARN"
  type        = string
}

variable "web_acl_id" {
  description = "Web ACL ARN of WAF"
  type        = string
}
