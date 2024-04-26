# Infrastructure Namespace Setups

## Instructions

To create run the following script.  Assumes aws cli configuration file present
in ~/.aws/config and has beem configured with the appropriate AWS Key ID, AWS Access Key
and AWS Default Region+

```
# ./create-infrastructure.sh
```

## Components

The following files comprise the items used to create the `infrastructure` namespace and resoruces contained therein.
- `create-infrastructure.sh` - The shell script to run.
- `Dockerfile` - Used to create the docker image that is used to generate and AWS ECR Docker Login token.
- `aws-ecr-role-and-cron.yaml` A Kube file object that defines the a service account, RBAC role and cronjob used to periodically update AWS ECR Docker Login ticket and attach it to the `default` service account of the configured `namespace`s
