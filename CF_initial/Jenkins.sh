#!/bin/bash -x
# Extracted shell code from Jenkins job. It's been sanitized and won't run as is.
#
# Previously in Jenkins variable parameters are passed and deployment code is checked out from scm.
# That includes puppet manifests, userdata script, and cloudformation templates.
FAIL=0
trap 'FAIL=1' ERR

cd $WORKSPACE
# This file creates a puppet archive and copies it to S3.
# It will be downloaded with the usedata script
/usr/bin/ruby tools/puppet_sync.rb

[ $FAIL -eq 0 ] && {

# Checkout Application code
  git clone -b $APP_BRANCH git@bitbucket.org:${APP_REPO} /tmp/$STACK_NAME

# Build the APP
  cd /tmp/$STACK_NAME/common
  /usr/local/maven/bin/mvn clean install

# Set build parameters
  cd /tmp/$STACK_NAME/$APP_NAME
  /usr/local/maven/bin/mvn $APP_BUILD_PARAMETER
}

[ $FAIL -eq 0 ] && {

# Copy the .war to s3
  cd /tmp/$STACK_NAME/$APP_NAME
  aws s3 cp target/${APP_NAME}.war s3://cfwdev-deployment/app/$STACK_NAME/
  cd $WORKSPACE
  rm -rf /tmp/$STACK_NAME

}

[ $FAIL -eq 0 ] && {

# This program builds the cloudformation template and creates a new cf stack.
# Userdata downloads the puppet archive from s3 to the instances and runs
  /usr/bin/ruby tools/build_stack.rb $APP_NAME $STACK_NAME

}

[ $FAIL -eq 0 ] && {

# Waits for the stack to be created - fails if it doesn't create
  /usr/bin/ruby tools/wait.rb $STACK_NAME

}

[ $FAIL -eq 0 ] && {

# Gets the instance id's and route53 records from the newly created stack
# Grabs and echoes the puppet log to the Jenkins console
  /usr/bin/ruby tools/instances_info.rb $STACK_NAME $LOG_OUTPUT

}

[ $FAIL -eq 0 ] && {

# Register new stack instances to the ELB and deregister the old stack instances
/usr/bin/ruby tools/control_elb.rb ${APP_NAME}-${APP_ENVIRONMENT} $STACK_NAME $MIN_AUTOSCALING_SIZE

}

[ $FAIL -eq 0 ] && {

# Deletes the old stack depending on the value in the $DELETE_ON variable
  /usr/bin/ruby tools/delete_stack.rb $STACK_NAME $DELETE_ON

}

exit $FAIL
