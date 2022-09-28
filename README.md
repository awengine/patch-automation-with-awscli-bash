# Purpose
Patching the EC2 instances used by an Autoscaling Group (ASG) once or monthly through automation. 


# Tools
Automation Document in Systems Manager (SSM), Lambda python functions, Cloudwatch rule, multiple IAM roles through AWS CLI and Bash.


# How does it work?
The script allows you to select an ASG and create an Automation Document to patch the ASG's AMI image once or monthly by scheduling a Cloudwatch rule. 

Once you run the script, it will ask you to select an existing ASG through prompt, then go through the following steps.

1. Creating and/or triggering the Lambda GetCurrentAMI to get the ASG's AMI ID and store it in Parameter Store.
2. Launching a new EC2 from the AMI.
3. Patching the EC2 - be Linux or Windows.
4. Stopping the EC2 and creating a new AMI from it. Terminating the EC2.
5. Creating and/or triggering the Lambda UpdateASG to create a new LC with the new AMI. Updating the ASG to use the new LC.
6. Creating and/or triggering the Lambda IncreaseASGCapacity to launch a new EC2 using the patched AMI.
7. Creating and/or triggering the Lambda DecreaseASGCapacity to terminate old EC2. 


# For Testing
If you don't have an existing ASG and LC (launch configuration) to test the script, you may refer to the following AWS CLI commands to quickly launch one. 

*Remember to replace the value of image-id, key-name, and vpc-zone-identifier based on your environment.*

*For example, image-id ami-02a599eb01e3b3c5b is Ubuntu 18.04, ami-0eb941b8e00feef88 is Windows 2019*

`aws autoscaling create-launch-configuration --launch-configuration-name your-LC-name --image-id ami-02a599eb01e3b3c5b --instance-type t2.micro --key-name your-private-key`

`aws autoscaling create-auto-scaling-group --auto-scaling-group-name your-asg-name --launch-configuration-name your-LC-name --min-size 1 --max-size 3 --vpc-zone-identifier "subnet-0ef5abe5710992b33,subnet-0ea175e0213db25a9"`
