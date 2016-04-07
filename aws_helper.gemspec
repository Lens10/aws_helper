Gem::Specification.new do |s|
  s.name        = 'aws_helper'
  s.version     = '0.0.0'
  s.date        = '2016-04-07'
  s.summary     = 'Manage AWS for DataTrue'
  s.description = 'A simple helper gem to deploy, setup and manage the DataTrue AWS environment.'
  s.authors     = ['Thiago Figueiró']
  s.email       = 'thiagofigueiro@lens10.com.au'
  s.files       = ['lib/aws_helper.rb',
                   'lib/aws_helper/client.rb']
  s.homepage    = 'https://github.com/Lens10/aws_helper'
  s.license     = 'Proprietary'

  s.add_runtime_dependency 'aws-sdk-v1', ['~> 1.66']
end
