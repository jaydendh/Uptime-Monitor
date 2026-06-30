import azure.functions as func
from azure.data.tables import TableServiceClient
import requests
import datetime
import json
import os
import logging

def main(mytimer: func.TimerRequest) -> None:
    """
    Runs every 5 minutes. Check the target website for:
    1. Reachability (does the server respond at all)
    2. Response time (is it fast enough to be usable)
    3. Content validity (is right content present?)
    """

    target_url = os.environ['TARGET_URL']
    storage_conn = os.environ["AzureWebJobsStorage"]
    check_time = datetime.datetime.utcnow()
    result_status = "PASS"
    error_details = None
    response_ms = None

    try:
        response = requests.get(target_url, timeout=10)
        response_ms = response.elapsed.total_seconds() * 1000

        if response.status_code != 200:
            result_status = "FAIL"
            error_details = f"HTTP {response.status_code}"
        elif response_ms > 5000:
            result_status = "SLOW"
            error_details = f"Response time {response_ms:.0f}ms exceeded 5000ms threshold"

        elif "error" in response.text.lower() and "404" in response.text:
            result_status = "FAIL"
            error_details = "Page contains error indicators"

    except requests.exceptions.ConnectionError:
        result_status = "FAIL"
        error_details = "Connection error: Unable to reach the server"
    except requests.exceptions.Timeout:
        result_staus = "FAIL"
        error_details = "Request timed out after 10 seconds"
    except Exception as e:
        result_status = "FAIL"
        error_details = str(e)

    entity = {
        "PartitionKey": target_url,
        "RowKey": check_time.strfttime("%Y%m%d%H%M%S"),
        "Timestamp": check_time.isoformat(),
        "Status": result_status,
        "ResponseTimeMs": int(response_ms) if response_ms else 0,
        "ErrorDetails": error_details or "",
        "TargetURL": target_url,
    }

    try:
        table_client.create_table_if_not_exists()
        table_client.upsert_entity(entity)
        logging.info(f"Check result: {result_status} | {response_ms:.0f}ms | {target_url}")
    except Exception as e:
        logging.error(f"failed to write result to table: {e}")

    if result_status != "PASS":
        logging.warning(f"Website check failed: {result_status} | {error_details} | {target_url}")
