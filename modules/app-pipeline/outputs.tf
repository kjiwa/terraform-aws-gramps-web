output "pipeline_name" {
  description = "CodePipeline name. Trigger with: scripts/deploy.sh gramps."
  value       = aws_codepipeline.this.name
}
