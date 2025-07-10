# Automate Daily Backups of AWS EC2 Instance to S3 Bucket using shell scripting

Prerequisites to implement this usecase

Couple of AWS EC2 instance and one should have installed with AWS CLI
IAM permissions for EC2 instance to create AMIs, EBS Snapshots and upload to S3
Amazon S3 bucket to store backup metadata (using AWS APIs)
Basic knowledge of shell scripting and cron jobs

# Steps to implement
  1. Create IAM role for EC2
  2. Create EC2 and attach IAM role
  3. Install AWS CLI
  4. Test the IAM role access from EC2
  5. Create the scritp to create AMI image and Upload
  6. Run the Script and verify AMI is uploaded to S3
