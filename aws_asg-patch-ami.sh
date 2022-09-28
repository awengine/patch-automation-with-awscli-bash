#!/bin/bash


### Introduction
cat <<INTRO

A few things before you run this script:

1. It assumes there's at least one existing ASG in the AWS account.
2. It patches the EC2 instances behind the selected ASG once or monthly.
3. Ensure that your machine has configured with AWS CLI with permissions required.

INTRO


### Check whether using the desired AWS account
ACCOUNTID=`aws sts get-caller-identity --query "Account" --output text`
ACCOUNTNAME=`aws organizations describe-account --account-id "$ACCOUNTID" --query "Account.Name"`
echo -e "\033[35m                         AWS Account ID: $ACCOUNTID\033[0m";
echo -e "\033[35m                         AWS Account Name: $ACCOUNTNAME\033[0m";


### Grab info about an existing ASG
# Print all ASG and select one. If only one ASG, it will automatically be selected.
mapfile -t ASG_ARRAY < <(aws autoscaling describe-auto-scaling-groups | jq -r '.AutoScalingGroups[].AutoScalingGroupName')
ASG_COUNT=${#ASG_ARRAY[@]}
if [ $ASG_COUNT -ge 2 ] ; then
   opt=0
      for i in "${ASG_ARRAY[@]}"
            do
                     opt=`expr $opt + 1`
                     printf "\t $opt) ${ASG_ARRAY[`expr $opt - 1`]}\n"
            done
            printf "\n\t\tSELECT ASG: "
            read select
            selected=`expr $select - 1`
            SelectedASG=`printf "%s\n" "${ASG_ARRAY[$selected]}" | cut -d$'\t' -f2`
   else
   SelectedASG=`printf "%s\n" "${ASG_ARRAY[@]}" | cut -d$'\t' -f2`
fi

SelectedASGnospace=`echo "${SelectedASG// /}"`

# Get/Set the AMIID and LC used by the ASG.
LC=`aws autoscaling describe-auto-scaling-groups --auto-scaling-group-name "$SelectedASG" | jq -r '.AutoScalingGroups[].LaunchConfigurationName'`
LC_CREATED_TIME=`aws autoscaling describe-auto-scaling-groups --auto-scaling-group-name "$SelectedASG" | jq -r '.AutoScalingGroups[].CreatedTime'`
AMIID=`aws autoscaling describe-launch-configurations --launch-configuration-names "$LC" | jq -r '.LaunchConfigurations[].ImageId'`
STAMP=`date +"%d%m%y%H%M"`
LOG="/home/$USER/log/$CLIENTID-$STAMP-patch-$SelectedASG-ami.log"

echo "The AMI used by ASG $SelectedASG is $AMIID"


### Create an IAM Role for the Automation Document if it doesn't exist.
function Create_Patch_Role {

aws iam create-role --role-name "asg-patch-ami-role" --assume-role-policy-document file://templates/aws/blank_iam_role &>> "$LOG"
aws iam attach-role-policy --role-name "asg-patch-ami-role" --policy-arn arn:aws:iam::aws:policy/AmazonSSMFullAccess
aws iam attach-role-policy --role-name "asg-patch-ami-role" --policy-arn arn:aws:iam::aws:policy/AWSLambdaExecute
aws iam attach-role-policy --role-name "asg-patch-ami-role" --policy-arn arn:aws:iam::aws:policy/AutoScalingFullAccess
aws iam attach-role-policy --role-name "asg-patch-ami-role" --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEC2RoleforSSM
AMI_PATCH_ROLE=`aws iam get-role --role-name "asg-patch-ami-role" --query "Role.Arn" --output text | cut -f1`

# Granting permissions as modified AmazonSSMAutomationRole
touch templates/aws/AmazonSSMAutomationRole.json
cat > templates/aws/AmazonSSMAutomationRole.json << SSMAUTO
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "lambda:InvokeFunction"
            ],
            "Resource": [
                "arn:aws:lambda:*:*:function:*Automation*"
            ]
        },
        {
            "Effect": "Allow",
            "Action": [
                "ec2:CreateImage",
                "ec2:CopyImage",
                "ec2:DeregisterImage",
                "ec2:DescribeImages",
                "ec2:DeleteSnapshot",
                "ec2:StartInstances",
                "ec2:RunInstances",
                "ec2:StopInstances",
                "ec2:TerminateInstances",
                "ec2:DescribeInstanceStatus",
                "ec2:CreateTags",
                "ec2:DeleteTags",
                "ec2:DescribeTags",
                "cloudformation:CreateStack",
                "cloudformation:DescribeStackEvents",
                "cloudformation:DescribeStacks",
                "cloudformation:UpdateStack",
                "cloudformation:DeleteStack"
            ],
            "Resource": [
                "*"
            ]
        },
        {
            "Effect": "Allow",
            "Action": [
                "ssm:*"
            ],
            "Resource": [
                "*"
            ]
        },
        {
            "Effect": "Allow",
            "Action": [
                "sns:Publish"
            ],
            "Resource": [
                "arn:aws:sns:*:*:*Automation*"
            ]
        }
    ]
}
SSMAUTO

aws iam put-role-policy --role-name asg-patch-ami-role --policy-name AmazonSSMAutomationRole --policy-document file://templates/aws/AmazonSSMAutomationRole.json

# Granting permissions to pass a role to those AWS services to be used.
touch "templates/aws/PassRole-$SelectedASG.json"
cat > "templates/aws/PassRole-$SelectedASG.json" << PASSROLE
{
    "Version": "2012-10-17",
    "Statement": [{
        "Effect": "Allow",
        "Action": [
            "iam:GetRole",
            "iam:PassRole"
        ],
        "Resource": "$AMI_PATCH_ROLE"
    }]
}
PASSROLE

cat "templates/aws/PassRole-$SelectedASG.json" | jq -e --arg resource "$AMI_PATCH_ROLE" '.Statement[].Resource = $resource' > "templates/aws/PassRole-$SelectedASG.json.tmp"
mv "templates/aws/PassRole-$SelectedASG.json.tmp" "templates/aws/PassRole-$SelectedASG.json"
aws iam put-role-policy --role-name asg-patch-ami-role --policy-name PassRolePolicy --policy-document "file://templates/aws/PassRole-$SelectedASG.json"

# Granting permissions to use KMS to decrypt/encrypt EBS attached to the EC2.
touch "templates/aws/KMSEncrypt-$SelectedASG.json"
cat > "templates/aws/KMSEncrypt-$SelectedASG.json" << KMSPOLICY
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "kms:DescribeKey",
                "kms:GenerateDataKey*",
                "kms:Encrypt",
                "kms:ReEncrypt*",
                "kms:Decrypt",
                "kms:ListGrants",
                "kms:CreateGrant",
                "kms:RevokeGrant"
            ],
            "Resource": "*"
        }
    ]
}
KMSPOLICY

aws iam put-role-policy --role-name asg-patch-ami-role --policy-name KMSEncryptPolicy --policy-document "file://templates/aws/KMSEncrypt-$SelectedASG.json"

# Create instance profile using the patch role.
aws iam create-instance-profile --instance-profile-name asg-patch-ami-role >> "$LOG"
aws iam add-role-to-instance-profile --instance-profile-name asg-patch-ami-role --role-name asg-patch-ami-role

}

PATCH_ROLE_EXIST=`aws iam get-role --role-name "asg-patch-ami-role" 2> /dev/null`
if [ -z "$PATCH_ROLE_EXIST" ] ; then
   echo "Creating the role 'asg-patch-ami-role' ..."
   Create_Patch_Role;
   else
   AMI_PATCH_ROLE=`aws iam get-role --role-name "asg-patch-ami-role" --query "Role.Arn" --output text | cut -f1`
   echo "Will use the existing role: $AMI_PATCH_ROLE "
fi


# Confirm with user before creating the Automation Document.
echo;
printf "%30s%25s\n" "Client ID: " "$CLIENTID"
printf "%30s%25s\n" "Target ASG: " "$SelectedASG"
printf "%30s%25s\n" "Target Launch Configuration: " "$LC"
printf "%30s%25s\n" "Target AMI to patch: " "$AMIID"
printf "%30s%25s\n" "IAM role: " "$AMI_PATCH_ROLE"
echo;

echo -n "Please confirm you would like to proceed (y/N): "
read CONFIRM
if [ -z $CONFIRM ] || [ $CONFIRM != "y" ] ; then
   echo "Quitting!"
   exit 1
fi


# Create a string in Parameter Store as Automation Document cannot consume lambda output internally.
PARANAME="$SelectedASG-currentAMI"
PARA_EXIST=`aws ssm get-parameter --name "$PARANAME" 2> /dev/null`
if [ -z "$PARA_EXIST" ] ; then
   echo "Creating the Parameter '$PARANAME' ..."
   aws ssm put-parameter --name "$PARANAME" --value "Initial Creation" --type "String" &>> "$LOG";
   else
   PARA1=`aws ssm get-parameter --name "$PARANAME" | jq -r '.Parameter.Name'`
   echo "Will use the existing AMI $PARA1"
fi
 

### If the lambda GetCurrentAMI doesn't exist, create it. Get the current AMI ID used, store it in Parameter Store.
function Create_Lambda_GetCurrentAMI {

touch templates/aws/GetCurrentAMI.py
cat > templates/aws/GetCurrentAMI.py <<GETAMI
from __future__ import print_function

import json
import boto3


def lambda_handler(event, context):
    print("Received event: " + json.dumps(event, indent=2))

    # Initiate an asg client
    asg = boto3.client('autoscaling')
    
    # Get the AMI ID used by the ASG
    asg_content = asg.describe_auto_scaling_groups(AutoScalingGroupNames=[event['targetASG']])
    LC = asg_content.get('AutoScalingGroups')[0]['LaunchConfigurationName']
    LC_content = asg.describe_launch_configurations(LaunchConfigurationNames=[LC])
    currentAMI = LC_content.get('LaunchConfigurations')[0]['ImageId']

    # Initiate a ssm client
    ssm = boto3.client('ssm')

    # Confirm  parameter exists before updating it
    para_exist = ssm.describe_parameters(
       Filters=[
          {
           'Key': 'Name',
           'Values': [ event['parameterName'] ]
          },
        ]
    )

    if not para_exist['Parameters']:
        print('No such parameter')
        return 'SSM parameter not found.'
    
    # Update the parameter value
    response = ssm.put_parameter(Name=event['parameterName'], Value=currentAMI, Type='String', Overwrite=True)

    return response

GETAMI

cd templates/aws/
chmod 644 GetCurrentAMI.py
zip GetCurrentAMI.zip GetCurrentAMI.py &>> "$LOG"
# handler format: filename.methodName
chmod 755 GetCurrentAMI.zip
FUNC1=`aws lambda create-function --function-name GetCurrentAMI --runtime python3.8 --role $AMI_PATCH_ROLE --handler GetCurrentAMI.lambda_handler --zip-file fileb://GetCurrentAMI.zip | jq -r '.FunctionName'`
cd ../..
echo "The lambda $FUNC1 is created."

}

FUNC1_EXIST=`aws lambda get-function --function-name GetCurrentAMI 2> /dev/null`
if [ -z "$FUNC1_EXIST" ] ; then
   echo "Creating the Lambda 'GetCurrentAMI' ..."
   Create_Lambda_GetCurrentAMI;
   else
   FUNC1=`aws lambda get-function --function-name GetCurrentAMI | jq -r '.Configuration.FunctionName'`
   echo "Will use the existing lambda $FUNC1"
fi


### If the lambda UpdateAsg doesn't exist, create it.
### The lambda will create a new Launch Configuration with the new AMIID, and update the ASG to use the new LC.
function Create_Lambda_UpdateASG {

touch templates/aws/UpdateAsg.py
cat > templates/aws/UpdateAsg.py <<UPDATEASG
from __future__ import print_function

import json
import datetime
import time
import boto3

print('Loading function')


def lambda_handler(event, context):
    print("Received event: " + json.dumps(event, indent=2))

    # get autoscaling client
    client = boto3.client('autoscaling')

    # get object for the ASG we're going to update, filter by name of target ASG
    response = client.describe_auto_scaling_groups(AutoScalingGroupNames=[event['targetASG']])

    if not response['AutoScalingGroups']:
        return 'No such ASG'

    # get name of InstanceID in current ASG that we'll use to model new Launch Configuration after
    sourceInstanceId = response.get('AutoScalingGroups')[0]['Instances'][0]['InstanceId']

    # create LC using instance from target ASG as a template, only diff is the name of the new LC and new AMI
    datenow = datetime.datetime.now()
    newLaunchConfigName = 'LC-' + event['targetASG'] + '-' + datenow.strftime("%Y%m%d-%H%M")
    client.create_launch_configuration(
        InstanceId = sourceInstanceId,
        LaunchConfigurationName=newLaunchConfigName,
        ImageId= event['newAmiID'] )

    # update ASG to use new LC
    response = client.update_auto_scaling_group(AutoScalingGroupName = event['targetASG'],LaunchConfigurationName = newLaunchConfigName)

    return 'Updated ASG %s with new launch configuration %s which includes AMI %s.' % (event['targetASG'], newLaunchConfigName, event['newAmiID'])

UPDATEASG

# Create the lambda at where the zip sits; or runtime error "cannot find the function" later.
cd templates/aws/
chmod 644 UpdateAsg.py
zip UpdateAsg.zip UpdateAsg.py &>> "$LOG"
# handler format: filename.methodName
chmod 755 UpdateAsg.zip
FUNC2=`aws lambda create-function --function-name UpdateAsg --runtime python3.8 --role $AMI_PATCH_ROLE --handler UpdateAsg.lambda_handler --zip-file fileb://UpdateAsg.zip | jq -r '.FunctionName'`
cd ../..
echo "The lambda $FUNC2 is created."

}

FUNC2_EXIST=`aws lambda get-function --function-name UpdateAsg 2> /dev/null`
if [ -z "$FUNC2_EXIST" ] ; then
   echo "Creating the Lambda 'UpdateAsg' ..."
   Create_Lambda_UpdateASG;
   else
   FUNC2=`aws lambda get-function --function-name UpdateAsg | jq -r '.Configuration.FunctionName'`
   echo "Will use the existing lambda $FUNC2"
fi


### If the lambda IncreaseASGCapacity doesn't exist, create it.
function Create_Lambda_IncreaseASGCapacity {

touch templates/aws/IncreaseASGCapacity.py
cat > templates/aws/IncreaseASGCapacity.py <<INCREASEASG
from __future__ import print_function

import json
import boto3
import time

print('Loading function')

def lambda_handler(event, context):
    print("Received event: " + json.dumps(event, indent=2))

    # Initiate autoscaling client
    client = boto3.client('autoscaling')

    # Get the target ASG
    asg = client.describe_auto_scaling_groups(AutoScalingGroupNames=[event['targetASG']])
    HealthCheckGracePeriod = asg.get('AutoScalingGroups')[0]['HealthCheckGracePeriod']
    
    if not asg['AutoScalingGroups']:
        return 'No such ASG'

    # Get the existing min/max/desired EC2 numbers in the ASG
    minsize = asg.get('AutoScalingGroups')[0]['MinSize']
    maxsize = asg.get('AutoScalingGroups')[0]['MaxSize']
    desiredsize = asg.get('AutoScalingGroups')[0]['DesiredCapacity']

    # Double the values of min/max/desired EC2 numbers.
    newMinsize = int(minsize*2)
    newMaxsize = int(maxsize*2)
    newDesired = int(desiredsize*2)

    # Set termination policy to OldestInstance
    client.update_auto_scaling_group(
        AutoScalingGroupName=event['targetASG'],
        MinSize=newMinsize, MaxSize=newMaxsize, DesiredCapacity=newDesired,
        TerminationPolicies=['OldestInstance'],
    )

    # Wait for the new launched EC2 to become healthy
    time.sleep(HealthCheckGracePeriod)

    return 'The new newMinsize is %s, newMaxsize is %s, newDesired is %s' % (newMinsize, newMaxsize, newDesired)

INCREASEASG

# Create the lambda at where the zip sits; or runtime error "cannot find the function" later.
cd templates/aws/
chmod 644 IncreaseASGCapacity.py
zip IncreaseASGCapacity.zip IncreaseASGCapacity.py &>> "$LOG"
# handler format: filename.methodName
chmod 755 IncreaseASGCapacity.zip
# Get target ASG's HealthCheckGracePeriod to set the function's timeout
HealthCheckGracePeriod=`aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$SelectedASG" --query 'AutoScalingGroups[].HealthCheckGracePeriod' --output text | cut -f 1`
FUNC4TIMEOUT=$(expr $HealthCheckGracePeriod + 20)
FUNC3=`aws lambda create-function --function-name IncreaseASGCapacity --runtime python3.8 --role $AMI_PATCH_ROLE --timeout $FUNC4TIMEOUT --handler IncreaseASGCapacity.lambda_handler --zip-file fileb://IncreaseASGCapacity.zip | jq -r '.FunctionName'`
cd ../..
echo "The lambda $FUNC3 is created."

}

FUNC3_EXIST=`aws lambda get-function --function-name IncreaseASGCapacity 2> /dev/null`
if [ -z "$FUNC3_EXIST" ] ; then
   echo "Creating the Lambda 'IncreaseASGCapacity' ..."
   Create_Lambda_IncreaseASGCapacity;
   else
   FUNC3=`aws lambda get-function --function-name IncreaseASGCapacity | jq -r '.Configuration.FunctionName'`
   echo "Will use the existing lambda $FUNC3"
fi


### If the lambda DecreaseASGCapacity doesn't exist, create it.
function Create_Lambda_DecreaseASGCapacity {

touch templates/aws/DecreaseASGCapacity.py
cat > templates/aws/DecreaseASGCapacity.py <<DECREASEASG
from __future__ import print_function

import json
import boto3
import time

print('Loading function')

def lambda_handler(event, context):
    print("Received event: " + json.dumps(event, indent=2))

    # Initiate autoscaling client
    client = boto3.client('autoscaling')

    # Get the existing Health Check Grace Period in the ASG
    asg = client.describe_auto_scaling_groups(AutoScalingGroupNames=[event['targetASG']])
    HealthCheckGracePeriod = asg.get('AutoScalingGroups')[0]['HealthCheckGracePeriod']

    # Wait for the new launched EC2 to become healthy (from IncreaseASGCapacity lambda)
    time.sleep(HealthCheckGracePeriod)

    # Get the existing min/max/desired EC2 numbers in the ASG
    minsize = asg.get('AutoScalingGroups')[0]['MinSize']
    maxsize = asg.get('AutoScalingGroups')[0]['MaxSize']
    desiredsize = asg.get('AutoScalingGroups')[0]['DesiredCapacity']

    # Divide the values of min/max/desired EC2 numbers by 2. Ensure the termination policy is OldestInstance again.
    newMinsize = int(minsize/2)
    newMaxsize = int(maxsize/2)
    newDesired = int(desiredsize/2)

    client.update_auto_scaling_group(
        AutoScalingGroupName=event['targetASG'],
        MinSize=newMinsize, MaxSize=newMaxsize, DesiredCapacity=newDesired,
        TerminationPolicies=['OldestInstance']
    )

    return 'The new newMinsize is %s, newMaxsize is %s, newDesired is %s' % (newMinsize, newMaxsize, newDesired)

DECREASEASG

# Create the lambda at where the zip sits; or runtime error "cannot find the function" later.
cd templates/aws/
chmod 644 DecreaseASGCapacity.py
zip DecreaseASGCapacity.zip DecreaseASGCapacity.py &>> "$LOG"
# handler format: filename.methodName
chmod 755 DecreaseASGCapacity.zip
# Get target ASG's HealthCheckGracePeriod to set the function's timeout
HealthCheckGracePeriod=`aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$SelectedASG" --query 'AutoScalingGroups[].HealthCheckGracePeriod' --output text | cut -f 1`
FUNC4TIMEOUT=$(expr $HealthCheckGracePeriod + 20)
FUNC4=`aws lambda create-function --function-name DecreaseASGCapacity --runtime python3.8 --role $AMI_PATCH_ROLE --timeout $FUNC4TIMEOUT --handler DecreaseASGCapacity.lambda_handler --zip-file fileb://DecreaseASGCapacity.zip | jq -r '.FunctionName'`
cd ../..
echo "The lambda $FUNC4 is created."

}

FUNC4_EXIST=`aws lambda get-function --function-name DecreaseASGCapacity 2> /dev/null`
if [ -z "$FUNC4_EXIST" ] ; then
   echo "Creating the Lambda 'DecreaseASGCapacity' ..."
   Create_Lambda_DecreaseASGCapacity;
   else
   FUNC4=`aws lambda get-function --function-name DecreaseASGCapacity | jq -r '.Configuration.FunctionName'`
   echo "Will use the existing lambda $FUNC4"
fi


### Create a SSM Automation Document to patch the selected AMI, save as a new AMI.
echo "Creating Automation Document..."
DOCNAME="Patch_AMI-$SelectedASGnospace"
touch "templates/aws/$DOCNAME.json"
cat > "templates/aws/$DOCNAME.json" << AUTODOC
{
   "description":"Systems Manager Automation – Patch AMI and Update LC for the ASG",
   "schemaVersion":"0.3",
   "assumeRole":"$AMI_PATCH_ROLE",
   "parameters":{
      "targetAMIname":{
         "type":"String",
         "description":"Name of new AMI",
         "default":"$SelectedASGnospace-{{global:DATE_TIME}}"
      },
      "targetASG":{
         "type":"String",
         "description":"Auto Scaling group to Update",
         "default":"$SelectedASG"
      },
      "docName":{
         "type":"String",
         "description":"Name of this Automation Document",
         "default":"$DOCNAME"
      },
      "parameterName":{
         "type":"String",
         "description":"Name of currentAMI in Parameter Store",
         "default":"$PARANAME"
      },
      "parameterValue":{
         "type":"String",
         "description":"Value of currentAMI in Parameter Store",
         "default":"{{ssm:$PARANAME}}"
      }
   },
   "mainSteps":[
      {
         "name":"getCurrentAMI",
         "action":"aws:invokeLambdaFunction",
         "timeoutSeconds":1200,
         "maxAttempts":1,
         "onFailure":"Abort",
         "inputs": {
            "FunctionName": "GetCurrentAMI",
            "Payload": "{\"targetASG\":\"{{targetASG}}\", \"parameterName\":\"{{parameterName}}\"}"
         }
      },
      {
         "name":"startInstances",
         "action":"aws:runInstances",
         "timeoutSeconds":1200,
         "maxAttempts":1,
         "onFailure":"Abort",
         "inputs":{
            "ImageId":"{{ parameterValue }}",
            "InstanceType":"t2.micro",
            "MinInstanceCount":1,
            "MaxInstanceCount":1,
            "IamInstanceProfileName":"asg-patch-ami-role"
         }
      },
      {
         "name":"runPatchBaseline",
         "action":"aws:runCommand",
         "maxAttempts":4,
         "timeoutSeconds":7200,
         "onFailure":"Continue",
         "inputs":{
            "DocumentName":"AWS-RunPatchBaseline",
            "InstanceIds":[
               "{{ startInstances.InstanceIds }}"
            ],
            "Parameters":{
               "Operation":"Install",
               "RebootOption":"RebootIfNeeded"
            }
         }
      },
      {
         "name":"stopInstance",
         "action":"aws:changeInstanceState",
         "maxAttempts":1,
         "onFailure":"Continue",
         "inputs":{
            "InstanceIds":[
               "{{ startInstances.InstanceIds }}"
            ],
            "DesiredState":"stopped"
         }
      },
      {
         "name":"createImage",
         "action":"aws:createImage",
         "maxAttempts":1,
         "onFailure":"Continue",
         "inputs":{
            "InstanceId":"{{ startInstances.InstanceIds }}",
            "ImageName":"{{ targetAMIname }}",
            "NoReboot":true,
            "ImageDescription":"AMI created by EC2 Automation"
         }
      },
      {
         "name":"terminateInstance",
         "action":"aws:changeInstanceState",
         "maxAttempts":1,
         "onFailure":"Continue",
         "inputs":{
            "InstanceIds":[
               "{{ startInstances.InstanceIds }}"
            ],
            "DesiredState":"terminated"
         }
      },
      {
         "name":"updateASG",
         "action":"aws:invokeLambdaFunction",
         "timeoutSeconds":1200,
         "maxAttempts":1,
         "onFailure":"Abort",
         "inputs": {
            "FunctionName": "UpdateAsg",
            "Payload": "{\"targetASG\":\"{{targetASG}}\", \"newAmiID\":\"{{createImage.ImageId}}\"}"
         }
      },
      {
         "name":"increaseASGCapacity",
         "action":"aws:invokeLambdaFunction",
         "timeoutSeconds":1200,
         "maxAttempts":1,
         "onFailure":"Abort",
         "inputs": {
            "FunctionName": "IncreaseASGCapacity",
            "Payload": "{\"targetASG\":\"{{targetASG}}\"}"
         }
      },
      {
         "name":"decreaseASGCapacity",
         "action":"aws:invokeLambdaFunction",
         "timeoutSeconds":1200,
         "maxAttempts":1,
         "onFailure":"Abort",
         "inputs": {
            "FunctionName": "DecreaseASGCapacity",
            "Payload": "{\"targetASG\":\"{{targetASG}}\"}"
         }
      }
   ],
   "outputs":[
      "createImage.ImageId"
   ]
}
AUTODOC

# Update the assumeRole ARN and targetASG in the Automation Document.
cat "templates/aws/$DOCNAME.json" | jq -e --arg role "$AMI_PATCH_ROLE" '.assumeRole = $role' > "templates/aws/$DOCNAME.json.tmp"
mv "templates/aws/$DOCNAME.json.tmp" "templates/aws/$DOCNAME.json"
cat "templates/aws/$DOCNAME.json" | jq -e --arg asg "$SelectedASG" '.parameters.targetASG.default = $asg' > "templates/aws/$DOCNAME.json.tmp"
mv "templates/aws/$DOCNAME.json.tmp" "templates/aws/$DOCNAME.json"
cat "templates/aws/$DOCNAME.json" | jq -e --arg doc "$DOCNAME" '.parameters.docName.default = $doc' > "templates/aws/$DOCNAME.json.tmp"
mv "templates/aws/$DOCNAME.json.tmp" "templates/aws/$DOCNAME.json"
cat "templates/aws/$DOCNAME.json" | jq -e --arg para "$PARANAME" '.parameters.parameterName.default = $para' > "templates/aws/$DOCNAME.json.tmp"
mv "templates/aws/$DOCNAME.json.tmp" "templates/aws/$DOCNAME.json"
# Create the doc in the Cloud
aws ssm create-document --name "$DOCNAME" --document-type "Automation" --content "file://templates/aws/$DOCNAME.json"


### Run the patch once now if desired.
function Patch_Now {

echo "Executing the ASG's AMI patching. Wait for 15 minutes..."
AUTOEXECID=`aws ssm start-automation-execution --document-name $DOCNAME | jq -r '.AutomationExecutionId'`
# Wait for 15 min to get the new AMI id
sleep 900
# Get error message or new AMI id based on execution result
EXECRESULT=`aws ssm get-automation-execution --automation-execution-id $AUTOEXECID | jq -r ' if .AutomationExecution.AutomationExecutionStatus == "Failed" then .AutomationExecution.FailureMessage else .AutomationExecution.Outputs."createImage.ImageId"[] end'`
if [[ $EXECRESULT == ami-* ]] ; then
   NEWAMI=$EXECRESULT
   echo "Patch success with new AMI ID: $NEWAMI"
   else
   echo "Execution status: $EXECRESULT"
   echo "If the patch takes longer than 15 min, it might show the above unsuccessful msg as well. "
   echo "Wait another 5 min and run 'aws ssm get-automation-execution --automation-execution-id $AUTOEXECID' to see the final outcome."
fi

}


### Schedule the patch monthly if desired.
function Patch_Monthly {

PATCH_RULE="$SelectedASG-MonthlyPatch"
aws events put-rule --name $PATCH_RULE --schedule-expression "cron(0 0 1 * ? *)" &>> "$LOG"
aws events put-targets --rule $PATCH_RULE --targets "Id"="1","Arn"="arn:aws:ssm:$AWS_REGION:$ACCOUNTID:automation-definition/$DOCNAME","RoleArn"="$AMI_PATCH_ROLE" &>> "$LOG"
RULE_STATE=`aws events describe-rule --name $PATCH_RULE | jq -r '.State'`
echo "The patch schedule is now: created and $RULE_STATE"

}


### Confirm to run once now and/or schedule monthly run.
cat <<RUNOPTION

There are three options to patch the selected ASG's AMI:
1. Run it once now.
2. Schedule a monthly patch only.
3. Run it now and schedule a monthly patch.

RUNOPTION
echo -n "Please enter a number corresponding to the patch run: "
read RUNSELECT
case "$RUNSELECT" in
   1) Patch_Now ;;
   2) Patch_Monthly ;;
   3) Patch_Monthly
      Patch_Now ;;
   *) echo "Invalid selection. Quitting. "
      exit 1 ;;
esac

echo;
echo "All done. "
echo;

