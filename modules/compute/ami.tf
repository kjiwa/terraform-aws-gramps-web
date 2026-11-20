# image_id is ignored on the launch templates (launch_template.tf), so
# replace_triggered_by is what makes a change of the pin reach them.
resource "terraform_data" "image_pin" {
  input = var.ami_pin
}
