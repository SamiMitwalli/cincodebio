from config import (JMS_ADDRESS, MINIO_FQDN, MINIO_SERVICE_PORT_MINIO_CONSOLE, MINIO_ACCESS_KEY,
                    MINIO_SECRET_KEY, MINIO_SERVICE_PORT, MINIO_EXTERNAL_HOST, MINIO_EXTERNAL_SECURE)

import requests
import json
import httpx
from minio import Minio



def get_minio_client(internal: bool = True) -> Minio:
    """
    Returns a Minio client object.

    The Minio client is initialized with the provided access key, secret key,
    and connection details.

    Returns:
        Minio: A Minio client object.

    """
    if internal:
        return Minio(
            f"{MINIO_FQDN}:{MINIO_SERVICE_PORT}",
            access_key=MINIO_ACCESS_KEY,
            secret_key=MINIO_SECRET_KEY,
            secure=False,
        )
    else:
        # `region` is set so minio-py does NOT make a bucket-region lookup call to the
        # external host when generating presigned URLs. Without it, generating a presigned
        # URL tries to reach MINIO_EXTERNAL_HOST (e.g. minio.localhost) from inside the
        # cluster and 500s when that host is only browser-resolvable. `secure` follows the
        # deployment (http for local via the ingress, https in production).
        return Minio(
            MINIO_EXTERNAL_HOST,
            access_key=MINIO_ACCESS_KEY,
            secret_key=MINIO_SECRET_KEY,
            secure=MINIO_EXTERNAL_SECURE,
            # This is the S3 "region" string. Its only purpose
            # here is to make minio-py use it directly instead of doing a bucket-region
            # lookup HTTP call to MINIO_EXTERNAL_HOST when signing presigned URLs (that call
            # is what 500s in-cluster). MinIO accepts any region and defaults to "us-east-1"
            # (MINIO_SITE_REGION is unset here), so "us-east-1" matches the server.
            region="us-east-1",
        )


def get_minio_session_token() -> requests.cookies.RequestsCookieJar:
    """
    Retrieves a session token from the Minio Console API.

    Returns:
        str: The session token.

    """
    # Set the URL for the POST request
    url = f'http://{MINIO_FQDN}:{MINIO_SERVICE_PORT_MINIO_CONSOLE}/api/v1/login'


    # Set the request headers
    headers = {'Content-Type': 'application/json'}

    # Create the JSON body
    body = json.dumps({
        'accessKey': MINIO_ACCESS_KEY,
        'secretKey': MINIO_SECRET_KEY
    }).encode('utf-8')

    # Set the request headers
    headers = {'Content-Type': 'application/json'}

    # Make the POST request with authentication
    response = requests.post(url, headers=headers, data=body)

    return response.cookies

def retrieve_prefix_for_job(job_id: str) -> str:

    # Retrieve the Job State Object for the job_id from the jobs API

    # Set the URL for the GET request

    url = f'http://{JMS_ADDRESS}/get-job-by-id/{job_id}'

    # Make the GET request
    response = requests.get(url)

    # If the request is successful, return the prefix
    if response.status_code == 200:
        # Return the root prefix from the job state object (workflow_id/TIME-STAMP-ROUTING_KEY/)
        return response.json()['root_prefix']
    else:
        return None


# Function that streams the file from the Minio Console API
async def stream_file(url: str, cookies: requests.cookies.RequestsCookieJar):
    async with httpx.AsyncClient(cookies=cookies) as client:
        async with client.stream("GET", url) as response:
            async for chunk in response.aiter_bytes():
                yield chunk