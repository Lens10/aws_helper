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

The default RAILS_ENV is `development`.  The default LOG_LEVEL is `WARN` and it accepts any of the [Logger levers](http://ruby-doc.org/stdlib-2.2.2/libdoc/logger/rdoc/Logger.html).


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

`add_instances(n)`: adds n instances to the current autoscale group.  The current autoscale group is the first one that matches the name filter.  Autoscale groups should sort naturally (see `create_autoscale_group` below) and the first match should always be the latest one to be created.

`create_autoscale_group(ami_id)`: creates a new auto scaling group configuration using `ami_id` to create its required launch configuration.  The following options are currently hard-coded: `key_name: 'id_lens10'`, `security_groups: ['sg-57142f2e']`, `instance_type: 't2.large'` (there are others, see `configure_autoscale_policies` in `lib/aws_helper.rb`).  It returns the name of the newly created auto scaling group in this format: `"#{CONFIG_NAME_BASE}#{Date.today.iso8601}_#{i}"`.

## AwsHelper::Client

### Class methods

None.

### Instance methods

`autoscale`: returns a [AWS::AutoScaling::Client](http://www.rubydoc.info/gems/aws-sdk-v1/1.66.0/AWS/AutoScaling/Client).

`cloudwatch`: returns [AWS::CloudWatch::Client](http://www.rubydoc.info/gems/aws-sdk-v1/1.66.0/AWS/CloudWatch/Client).

`ec2`: returns a [AWS::EC2::Client](http://www.rubydoc.info/gems/aws-sdk-v1/1.66.0/AWS/EC2/Client).

# To do
* Write tests
* Remove hard-coded options
* Make it generic, rename and publish in rubygem
