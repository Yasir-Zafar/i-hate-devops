# CV hosted on AWS (23L-3029)

My CV is served twice from one private S3 bucket: by Apache on an EC2 instance, and by a Python Lambda function behind a function URL.

- EC2 site: `http://13.48.147.35` (instance `i-05c343c6907ef2f50`)
- Lambda site: `https://bmebv2wos5rltteywf63vmzhsa0oxepg.lambda-url.eu-north-1.on.aws/`
- Region: `eu-north-1` (Stockholm)

| Resource | Name |
|---|---|
| S3 bucket | `cv-23l-3029` |
| EC2 instance | `cv-ec2-23l-3029` |
| EC2 role | `cv-ec2-role-23l-3029` |
| Lambda function | `cv-func-23l-3029` |
| Lambda role | `cv-lambda-role-23l-3029` |

The bucket, instance, function and both roles are tagged `Owner=23l-3029` and `Course=cloud`.

## Architecture

```
                      Internet visitors
              ┌─────────────────┴──────────────────┐
         HTTP :80                                HTTPS
              │                                     │
              ▼                                     ▼
 ┌──────────────────────────────┐   ┌───────────────────────────────┐
 │ EC2  cv-ec2-23l-3029         │   │ Lambda function URL (auth     │
 │ Amazon Linux 2023, Apache    │   │ NONE)  cv-func-23l-3029       │
 │ systemd timer -> sync-cv.sh  │   │ Python, 256 MB, 10 s timeout  │
 │ role cv-ec2-role-23l-3029    │   │ role cv-lambda-role-23l-3029  │
 └──────────────┬───────────────┘   └───────────────┬───────────────┘
   s3:ListBucket (prefix site/)                     │ s3:GetObject
   + s3:GetObject, every 2 min                      │ on every request
                │                                   │
                └─────────────────┬─────────────────┘
                                  ▼
                 ┌──────────────────────────────────┐
                 │ S3 bucket cv-23l-3029            │
                 │ private, Block Public Access on, │
                 │ versioning on, no bucket policy  │
                 │   site/index.html                │
                 │   site/style.css                 │
                 │   site/cv.pdf                    │
                 └──────────────────────────────────┘
```

**Path A (EC2).** A browser connects to the instance's public IPv4 address on port 80, which the security group allows, and Apache returns the file from `/var/www/html`. That folder is refreshed every 2 minutes by `sync-cv.sh`, which copies the `site/` prefix from S3 with the instance role and replaces the footer placeholder with `EC2` and the instance ID.

**Path B (Lambda).** A browser sends an HTTPS request to the function URL, which invokes `lambda_handler` with the request path. The function reads the matching object from S3 with its execution role, replaces the footer placeholder with `Lambda` and the function name, and returns the file (the PDF base64 encoded).

## Repository layout

```
README.md
collect-evidence.sh   evidence script (bucket, EC2 address, Lambda address)
evidence.txt          output of my own run of the script
site/                 index.html, style.css, cv.pdf  (the three objects in S3)
ec2/                  user-data.sh, sync-cv.sh
lambda/               lambda_function.py
iam/                  trust and permission JSON of both roles
```

To publish a change: edit `site/`, then `aws s3 sync site/ s3://cv-23l-3029/site/ --delete`. The EC2 site follows within 2 minutes (the timer); the Lambda site follows immediately, apart from the 60 second browser cache on the page.

## Evidence

### Access denied on the instance (section 4)

Run from a shell on the instance through EC2 Instance Connect, as the instance role. Deleting and overwriting are denied; the role can list only the `site/` prefix:

```
$ aws sts get-caller-identity --query Arn --output text
arn:aws:sts::730335630880:assumed-role/cv-ec2-role-23l-3029/i-05c343c6907ef2f50

$ aws s3 rm s3://cv-23l-3029/site/index.html
delete failed: s3://cv-23l-3029/site/index.html An error occurred (AccessDenied) when calling the DeleteObject operation: User: arn:aws:sts::730335630880:assumed-role/cv-ec2-role-23l-3029/i-05c343c6907ef2f50 is not authorized to perform: s3:DeleteObject on resource: "arn:aws:s3:::cv-23l-3029/site/index.html" because no identity-based policy allows the s3:DeleteObject action

$ aws s3 cp /etc/hostname s3://cv-23l-3029/site/index.html
upload failed: ../../etc/hostname to s3://cv-23l-3029/site/index.html An error occurred (AccessDenied) when calling the PutObject operation: User: arn:aws:sts::730335630880:assumed-role/cv-ec2-role-23l-3029/i-05c343c6907ef2f50 is not authorized to perform: s3:PutObject on resource: "arn:aws:s3:::cv-23l-3029/site/index.html" because no identity-based policy allows the s3:PutObject action

$ aws s3 ls s3://cv-23l-3029/ --recursive   (not allowed: ListBucket only for prefix site/)

aws: [ERROR]: An error occurred (AccessDenied) when calling the ListObjectsV2 operation: User: arn:aws:sts::730335630880:assumed-role/cv-ec2-role-23l-3029/i-05c343c6907ef2f50 is not authorized to perform: s3:ListBucket on resource: "arn:aws:s3:::cv-23l-3029" because no identity-based policy allows the s3:ListBucket action

$ aws s3 ls s3://cv-23l-3029/site/   (allowed)
2026-10-24 17:38:18      57196 cv.pdf
2026-10-24 17:38:15       2216 index.html
2026-10-24 17:38:17       1294 style.css
```

### Last 10 lines of `/var/log/cv-sync.log`

```
2026-10-24T17:40:32Z sync=OK instance=i-05c343c6907ef2f50 bucket=cv-23l-3029
2026-10-24T17:41:00Z sync=OK instance=i-05c343c6907ef2f50 bucket=cv-23l-3029
2026-10-24T17:43:00Z sync=OK instance=i-05c343c6907ef2f50 bucket=cv-23l-3029
2026-10-24T17:45:00Z sync=OK instance=i-05c343c6907ef2f50 bucket=cv-23l-3029
2026-10-24T17:47:00Z sync=OK instance=i-05c343c6907ef2f50 bucket=cv-23l-3029
2026-10-24T17:49:00Z sync=OK instance=i-05c343c6907ef2f50 bucket=cv-23l-3029
2026-10-24T17:51:00Z sync=OK instance=i-05c343c6907ef2f50 bucket=cv-23l-3029
2026-10-24T17:53:01Z sync=OK instance=i-05c343c6907ef2f50 bucket=cv-23l-3029
2026-10-24T17:55:01Z sync=OK instance=i-05c343c6907ef2f50 bucket=cv-23l-3029
2026-10-24T17:57:01Z sync=OK instance=i-05c343c6907ef2f50 bucket=cv-23l-3029
```

## Written answers

**1. Why do the instance and the function use roles instead of access keys? What could go wrong if the keys were in the user data?**
A role gives the instance or the function short-lived credentials that AWS creates, delivers (through the metadata service or the Lambda environment) and rotates by itself, so there is no secret for me to store, copy or forget. Keys in the user data would be long-lived, and user data can be read from the console and API, from the instance's metadata and from `/var/log/user-data.log`. If the script were also committed to this public repository, bots that scan GitHub would find the keys within minutes and could read, delete or run up charges in my account until I deactivated them.

**2. Someone pastes the S3 address of index.html into a browser. What do they see, and which setting causes that?**
They see an XML error page with `AccessDenied` (HTTP 403), not the CV. The cause is that all four Block Public Access settings are on and there is no bucket policy or ACL granting anything to everyone, so an anonymous request has no permission to read the object. Block Public Access is the setting that would also keep it denied if someone added a public policy by mistake.

**3. Explain in your own words the permission on the function URL that lets anyone call it. Why is that acceptable for the function but not for the bucket?**
It is a resource-based policy statement on the function with principal `*`, action `lambda:InvokeFunctionUrl` and the condition that the URL's auth type is `NONE` (the console also adds `lambda:InvokeFunction` limited to calls made through the URL), which means anybody on the Internet may call the URL without signing the request. That is acceptable because the function is the public front door: it can only return the three fixed files, and its role cannot read anything outside `site/` or write anything. Making the bucket public would let anyone read every object directly, including future private ones, and would skip the code that decides what is served, so the data stays private and only the function is exposed.

**4. Compare the two paths. What do you pay for when nobody visits the site? What happens if the traffic grows a hundred times?**
With no visitors the EC2 path still costs money every hour (the instance, its EBS disk and its public IPv4 address, which only the Free Tier or credits cover), while Lambda costs nothing for compute because it is billed per request and per millisecond; on both paths only the tiny S3 storage and log storage remain. With a hundred times the traffic, Lambda starts more copies of itself automatically and its cost grows with the number of requests, up to the account concurrency limit. The single small instance would eventually run out of CPU or network capacity, and I would have to resize it or add more instances and a load balancer myself, and until then visitors would see slow or failed responses.

**5. You delete the EC2 instance. What do you lose and what do you still have?**
I lose the running web server, its public IP address (a new instance would get a different one, so the old address stops working), its disk with the synced copy of the site and `/var/log/cv-sync.log`, and the instance ID shown in the footer. I still have the S3 bucket with all objects and versions, the IAM roles and policies, the security group, the Lambda site (which keeps working), and this repository. Launching a new instance with `ec2/user-data.sh` rebuilds the same site in a few minutes.

## Sources and tools

- AWS documentation: S3 Block Public Access, IAM roles for EC2 and instance profiles, IMDSv2, Lambda function URLs and their resource-based policy, CloudWatch Logs retention.
- Course material for the lab brief and naming rules.
- AI assistance: the scripts, policies and this README were drafted with Claude Code (an AI coding assistant).
