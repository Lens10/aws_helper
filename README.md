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
```

The default RAILS_ENV is `development`.


# Full list of methods

## AwsHelper

### Class methods
`get_self_instance_id`: if called from an EC2 instance returns the instance ID, otherwise returns `NOT_AN_EC2_INSTANCE`.

### Instance methods

`reboot_instances`: reboots all instances tagged with `project=tagtrue` and `environment=RAILS_ENV`.

## AwsHelper::Client

### Class methods

None.

### Instance methods

`autoscale`: returns a [AWS::AutoScaling::Client](http://www.rubydoc.info/gems/aws-sdk-v1/1.66.0/AWS/AutoScaling/Client).

`cloudwatch`: returns [AWS::CloudWatch::Client](http://www.rubydoc.info/gems/aws-sdk-v1/1.66.0/AWS/CloudWatch/Client).

`ec2`: returns a [AWS::EC2::Client](http://www.rubydoc.info/gems/aws-sdk-v1/1.66.0/AWS/EC2/Client).
