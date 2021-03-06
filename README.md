# aws_helper

A helper rubygem to manage DataTrue AWS instances.

# Usage

Add to your `Gemfile`:

```Gemfile
gem 'aws_helper', :git => 'https://github.com/lens10/aws_helper.git'
```

Then
```ruby
c = AwsHelper::Client.new(access_key_id: 'key_id_here',
                          secret_access_key: 'secret_here',
                          region: 'us-east-1')
i = c.ec2.instances.filter('instance-state-name', 'running')
i.each do |instance| puts "#{instance.id} (#{instance.tags['Name']},#{instance.private_ip_address})" end
```

Example output from code above:
```bash
i-00c575c3105c337bb (tagtrue-production-autoscale,172.31.54.69)
i-0a6b02d33a5795820 (tagtrue-staging-autoscale,172.31.52.55)
i-0a6f5a4e380422a29 (bastion,172.31.98.154)
```

# Environment variables
If you don't provide parameters when instantiating the Client class it will look for these equivalent environment variables:

```bash
AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY
AWS_REGION
```

The default region is `us-east-1`.

```bash
RAILS_ENV
LOG_LEVEL
```

The default RAILS_ENV is `development`.  The default LOG_LEVEL is `WARN` and it accepts any of the [Logger levels](http://ruby-doc.org/stdlib-2.2.2/libdoc/logger/rdoc/Logger.html).


# Full list of methods

## AwsHelper

### Class methods

`get_self_instance_id`: if called from an EC2 instance returns the instance ID, otherwise returns `NOT_AN_EC2_INSTANCE`.

### Instance methods

`reboot_instances`: reboots all instances tagged with `project=tagtrue` and `environment=RAILS_ENV`.  Returns status, count.  Count is the number of instances rebooted. Status return values meaning:
* 0 all instances were rebooted successfully;
* 1 no target instances to reboot were found;
* 2 timeout occurred while waiting for an instance to stop; count will contain the number of instances stopped so far.
* 3 timeout occurred while waiting for an instance to start; count will contain the number of instances rebooted so far.

`get_leader_instance_id`: returns the instance ID of the leader in a group of instances tagged with `project=tagtrue` and `environment=RAILS_ENV`.  The algorithm simply consists of sorting all instances by ID and returning the first one.

`get_running_worker_instances`: finds all running instances with tags matching `environment=ENV['RAILS_ENV']` and `project=AwsHelper::PROJECT_TAG`.  Returns an `AWS::EC2::InstanceCollection` and an `Array` of instance IDs.

`add_instances(n)`: adds n instances to the current autoscale group.  The current autoscale group is the first one that matches the name filter.  Autoscale groups should sort naturally (see `create_autoscale_group` below) and the first match should always be the latest one to be created.  Returns the autoscale group's new desired capacity.

`create_autoscale_group(ami_id, associate_public_ip=false)`: creates a new auto
scaling group configuration using `ami_id` to create its required launch
configuration.  The following options are currently hard-coded: `key_name`,
`security_groups`, `instance_type` (see `configure_autoscale_policies` in
`lib/aws_helper.rb` for values and other options).  It returns the name of the newly created auto
scaling group in this format:
`"#{CONFIG_NAME_BASE}#{Date.today.iso8601}_#{i}"`.

`set_instance_userdata(id, data)`: **stops** ec2 instance with instance_id `id` and writes `data` to the [instance user-data storage](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-instance-metadata.html#instancedata-add-user-data). The instance user data can be accessed locally, e.g.: `curl http://169.254.169.254/latest/user-data`.

`create_tagtrue_image(instance_id, version)`: **stops** instance `instance_id` and uses it as a base to create an AMI which is named and tagged after `version`.  Returns an instance of [AWS::EC2::Image](http://www.rubydoc.info/gems/aws-sdk-v1/1.66.0/AWS/EC2/Image) on success.

`cleanup_autoscale_groups(keep_asg_name)`: deletes all auto scaling groups that are older than AWS_OBJECT_CLEANUP_AGE, match the naming convention, are tagged with `environment=RAILS_ENV` and do not match `keep_asg_name`.  If the auto scaling group is not older than AWS_OBJECT_CLEANUP_AGE its `min_size`, `max_size` and `desired_capacity` are set to zero.

`cleanup_launch_configurations`: deletes all launch configurations older than AWS_OBJECT_CLEANUP_AGE and not in use (i.e. don't have an associated auto scaling group).

`cleanup_instances`: terminates all stopped instances older than AWS_OBJECT_CLEANUP_AGE that are tagged with `project=PROJECT_TAG`.  The method doesn't check the instance name because it's not responsible for naming instances and, hence, doesn't know what the naming standard is.

`cleanup_amis`: unregisters all AMIs that are older than AWS_OBJECT_CLEANUP_AGE, are not associated with a launch configuration and match the naming convention.

## AwsHelper::Client

### Class methods

None.

### Instance methods

`autoscale`: returns a [AWS::AutoScaling::Client](http://www.rubydoc.info/gems/aws-sdk-v1/1.66.0/AWS/AutoScaling/Client).

`cloudwatch`: returns [AWS::CloudWatch::Client](http://www.rubydoc.info/gems/aws-sdk-v1/1.66.0/AWS/CloudWatch/Client).

`ec2`: returns a [AWS::EC2::Client](http://www.rubydoc.info/gems/aws-sdk-v1/1.66.0/AWS/EC2/Client).

# AWS IAM Policy

This is the full set of permissions needed to operate all methods of this gem.  Start with this and remove what you don't need.

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "Stmt1460173333000",
            "Effect": "Allow",
            "Action": [
                "ec2:CreateTags",
                "ec2:CreateImage",
                "ec2:DeregisterImage",
                "ec2:DescribeImages",
                "ec2:DescribeInstanceStatus",
                "ec2:DescribeInstances",
                "ec2:DescribeTags",
                "ec2:StopInstances"
            ],
            "Resource": [ "*" ]
        },
        {
            "Sid": "Stmt1460173476000",
            "Effect": "Allow",
            "Action": [
                "autoscaling:CreateAutoScalingGroup",
                "autoscaling:CreateLaunchConfiguration",
                "autoscaling:CreateOrUpdateTags",
                "autoscaling:DeleteAutoScalingGroup",
                "autoscaling:DeleteLaunchConfiguration",
                "autoscaling:DescribeAutoScalingGroups",
                "autoscaling:DescribeLaunchConfigurations",
                "autoscaling:DescribeTags",
                "autoscaling:PutScalingPolicy",
                "autoscaling:UpdateAutoScalingGroup",
                "autoscaling:SetDesiredCapacity"
                "cloudwatch:PutMetricAlarm"
            ],
            "Resource": [ "*" ]
        }
    ]
}
```

# To do
* Write tests
* Remove hard-coded options
* Make it generic, rename and publish in rubygem
