require File.expand_path('lib/cfntemplate', File.dirname(__FILE__))
#
# This template is non-executable and is to be used for demonstration purposes only.
# All referenced AWS assets such as arn, security groups and subnets are currently
# non-existant.
# ----------------------------------------------------------------------------
# ENV based variables
# ----------------------------------------------------------------------------

case ENV['APP_ENVIRONMENT']
when 'stage'
  sgroup=['sg-a10e40d9']
  subnets=['subnet-0a072e53', 'subnet-788dd253', 'subnet-47dec930', 'subnet-ad5b9b90']
when 'prod'
  sgroup=['sg-b7054bcf']
  subnets=['subnet-f1f9bea8', 'subnet-ab254e80', 'subnet-21ebc756', 'subnet-9eeff2a4']
end

# ----------------------------------------------------------------------------
# Create the CloudFormation template.
# ----------------------------------------------------------------------------

template do

  value :AWSTemplateFormatVersion => '2010-09-09'

  value :Description => "Stack of "+ENV['APP_NAME']+" application. Environment: "+ENV['APP_ENVIRONMENT']

  parameter 'Environment',
            :Description           => 'Env to launch in (dev, qa, stg, prod)',
            :Type                  => 'String',
            :AllowedValues         => [ 'dev', 'stage', 'prod', 'demo' ],
            :ConstraintDescription => 'Must be a valid environment name.',
            :Default               => ENV['APP_ENVIRONMENT']

  parameter 'InstanceType',
            :Description           => 'EC2 instance type',
            :Type                  => 'String',
            :ConstraintDescription => 'Must be a valid EC2 instance type.',
            :Default               => ENV['INSTANCE_TYPE']

  resource 'S3IAMRole', :Type => 'AWS::IAM::Role', :Properties => {
    :Path                     => '/',
    :AssumeRolePolicyDocument => {
      :Statement              => [ {
        :Effect    => "Allow",
        :Principal => {
          :Service => [ "ec2.amazonaws.com" ]
        },
        :Action    => [ "sts:AssumeRole" ]
      } ]
    }
  }

  resource 'S3IAMPolicy', :Type => 'AWS::IAM::Policy', :Properties => {
    :PolicyName     => "root",
    :Roles          => [ ref('S3IAMRole') ],
    :PolicyDocument => {
      :Statement => [
        {
          :Action   => ["iam:PassRole"],
          :Effect   => "Allow",
          :Resource => [ "*" ]
        },
        {
          :Action   => ["s3:ListAllMyBuckets"],
          :Effect   => "Allow",
          :Resource => ["arn:aws:s3:::*"]
        },
        {
          :Action   => ["s3:*"],
          :Effect   => "Allow",
          :Resource => [
            "arn:aws:s3:::cf-deployment",
            "arn:aws:s3:::cf-deployment/*",
			]
        },
		{
            :Action   => ["route53:ChangeResourceRecordSets"],
            :Effect   => "Allow",
            :Resource => ["arn:aws:route53:::hostedzone/XXXXXXXXXXXXX"]

        },
        {
            :Action   => ["route53:GetChange"],
            :Effect   => "Allow",
            :Resource => ["arn:aws:route53:::change/*"]
        },

	{
            :Action   => ["cloudwatch:*"],
            :Effect   =>  "Allow",
            :Resource => ["*"]
        },
        {
            :Action   => ["ec2:DescribeTags"],
            :Effect   =>  "Allow",
            :Resource => ["*"]
        }
      ]
    }
  }

  resource 'InstanceIAM', :Type => 'AWS::IAM::InstanceProfile', :Properties => {
    :Path  => '/',
    :Roles => [ ref('S3IAMRole') ]
  }

  resource 'AutoScalingGroup', :Type => 'AWS::AutoScaling::AutoScalingGroup', :Properties => {
      :AvailabilityZones         => ['us-east-1a', 'us-east-1c', 'us-east-1d', 'us-east-1e'],
	  :VPCZoneIdentifier         => subnets,
      :LaunchConfigurationName   => ref('LaunchConfig'),
      :HealthCheckGracePeriod    => '800',
      :HealthCheckType           => 'EC2',
      :LoadBalancerNames         => [ ENV['APP_NAME']+'-'+ENV['APP_ENVIRONMENT'] ],
      :MinSize                   => ENV['MIN_AUTOSCALING_SIZE'],
      :MaxSize                   => ENV['MAX_AUTOSCALING_SIZE'],
      :Tags                     => [
        {
          :Key                =>  'Name',
          :Value              =>  ENV['APP_NAME']+'-'+ENV['APP_ENVIRONMENT']+'-'+ENV['BUILD_NUMBER'],
          :PropagateAtLaunch => 'true'
        },
        {
          :Key               => 'Environment',
          :Value             => ref('Environment'),
          :PropagateAtLaunch => 'true'
        },
        {
          :Key               => 'App',
          :Value             => 'social-wp',
          :PropagateAtLaunch => 'true'
        },
            {
          :Key   => 'Tier',
          :Value => 'API',
          :PropagateAtLaunch => 'true'
        }
	]
  }

  resource 'LaunchConfig', :Type => 'AWS::AutoScaling::LaunchConfiguration', :Properties => {
	  :ImageId             => 'ami-3c563a2a',
	  :KeyName             => ENV['APP_ENVIRONMENT'],
	  :InstanceType        => ref('InstanceType'),
	  :InstanceMonitoring  => 'true',
          :IamInstanceProfile => ref('InstanceIAM'),
	  :SecurityGroups      => sgroup,
	  :BlockDeviceMappings => [
        {
          :DeviceName  => '/dev/sdb',
          :VirtualName => 'ephemeral0'
        },
	  ],
	  :UserData            => base64(join_interpolate("\n", file('userdata/default.sh')))
  }

    resource 'ScaleUpPolicy', :Type => 'AWS::AutoScaling::ScalingPolicy', :Properties => {
      :AdjustmentType       => 'ChangeInCapacity',
      :AutoScalingGroupName => ref('AutoScalingGroup'),
      :Cooldown             => '60',
      :ScalingAdjustment    => '1'
  }

  resource 'ScaleDownPolicy', :Type => 'AWS::AutoScaling::ScalingPolicy', :Properties => {
      :AdjustmentType       => 'ChangeInCapacity',
      :AutoScalingGroupName => ref('AutoScalingGroup'),
      :Cooldown             => '60',
      :ScalingAdjustment    => '-1'
  }


  resource 'CPUUtilAlarmHigh', :Type => 'AWS::CloudWatch::Alarm', :Properties => {
      :AlarmDescription   => 'Scale-up if CPU > 90% for 7 minutes',
      :MetricName         => 'CPUUtilization',
      :Namespace          => 'AWS/EC2',
      :Statistic          => 'Average',
      :Period             => '60',
      :EvaluationPeriods  => '7',
      :Threshold          => '90',
      :ComparisonOperator => 'GreaterThanThreshold',
      :AlarmActions       => [ ref('ScaleUpPolicy') ],
      :Dimensions         => [
        {
          :Name  => 'AutoScalingGroupName',
          :Value => ref('AutoScalingGroup')
        }
      ]
  }

  resource 'CPUUtilAlarmLow', :Type => 'AWS::CloudWatch::Alarm', :Properties => {
      :AlarmDescription   => 'Scale-down if CPU < 70% for 10 minutes',
      :MetricName         => 'CPUUtilization',
      :Namespace          => 'AWS/EC2',
      :Statistic          => 'Average',
      :Period             => '60',
      :EvaluationPeriods  => '10',
      :Threshold          => '70',
      :ComparisonOperator => 'LessThanThreshold',
      :AlarmActions       => [ ref('ScaleDownPolicy') ],
      :Dimensions         => [
        {
          :Name  => 'AutoScalingGroupName',
          :Value => ref('AutoScalingGroup')
        }
      ]
  }

  resource 'ScaleUpPolicyM', :Type => 'AWS::AutoScaling::ScalingPolicy', :Properties => {
      :AdjustmentType       => 'ChangeInCapacity',
      :AutoScalingGroupName => ref('AutoScalingGroup'),
      :Cooldown             => '60',
      :ScalingAdjustment    => '1'
  }

  resource 'ScaleDownPolicyM', :Type => 'AWS::AutoScaling::ScalingPolicy', :Properties => {
      :AdjustmentType       => 'ChangeInCapacity',
      :AutoScalingGroupName => ref('AutoScalingGroup'),
      :Cooldown             => '60',
      :ScalingAdjustment    => '-1'
  }

  resource 'MEMUtilAlarmHigh', :Type => 'AWS::CloudWatch::Alarm', :Properties => {
      :AlarmDescription   => 'Scale-up if MEM > 80% for 10 minutes',
      :MetricName         => 'MemoryUtilization',
      :Namespace          => 'AWS/EC2',
      :Statistic          => 'Average',
      :Period             => '60',
      :EvaluationPeriods  => '10',
      :Threshold          => '80',
      :ComparisonOperator => 'GreaterThanThreshold',
      :AlarmActions       => [ ref('ScaleUpPolicyM') ],
      :Dimensions         => [
        {
          :Name  => 'AutoScalingGroupName',
          :Value => ref('AutoScalingGroup')
        }
      ]
  }

  resource 'MEMUtilAlarmLow', :Type => 'AWS::CloudWatch::Alarm', :Properties => {
      :AlarmDescription   => 'Scale-down if MEM < 80% for 10 minutes',
      :MetricName         => 'MemoryUtilization',
      :Namespace          => 'AWS/EC2',
      :Statistic          => 'Average',
      :Period             => '60',
      :EvaluationPeriods  => '10',
      :Threshold          => '80',
      :ComparisonOperator => 'LessThanThreshold',
      :AlarmActions       => [ ref('ScaleDownPolicyM') ],
      :Dimensions         => [
        {
          :Name  => 'AutoScalingGroupName',
          :Value => ref('AutoScalingGroup')
        }
      ]
  }

  resource 'WaitConditionHandle', :Type => 'AWS::CloudFormation::WaitConditionHandle', :Properties => {}

  resource 'WaitCondition', :Type => 'AWS::CloudFormation::WaitCondition', :DependsOn => 'AutoScalingGroup', :Properties => {
      :Handle  => ref('WaitConditionHandle'),
      :Timeout => 1500,
      # Each launched instance is going to trigger one wait condition, so we
      # want to wait for one from each of the instances we expect to launch.
      :Count   => ENV['MIN_AUTOSCALING_SIZE'],
  }

end.exec!
