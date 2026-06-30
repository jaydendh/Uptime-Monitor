variable "yourname" {
  description = "name of the project"
  type = string
}

variable "location" {
  description = "Azure region to deploy resources"
  type = string
}

variable "target_url" {
  description = "URL to monitor"
  type = string
}

variable "alert_email" {
  description = "Email address to send alerts"
  type = string
}

variable "alert_phone" {
  description = "Phone number to send alerts"
  type = string
}