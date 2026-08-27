import imessage_client


def test_parse_webhook_event_basic_text():
    payload = {
        "type": "new-message",
        "data": {
            "isFromMe": False,
            "text": "CVS $8.50 health",
            "handle": {"address": "+15555550123"},
            "attachments": [],
        },
    }
    event = imessage_client.parse_webhook_event(payload)
    assert event == {"from": "+15555550123", "body": "CVS $8.50 health", "media_url": None}


def test_parse_webhook_event_ignores_own_outbound_echo():
    payload = {
        "type": "new-message",
        "data": {"isFromMe": True, "text": "reply", "handle": {"address": "+15555550123"}},
    }
    assert imessage_client.parse_webhook_event(payload) is None


def test_parse_webhook_event_ignores_other_event_types():
    assert imessage_client.parse_webhook_event({"type": "typing-indicator", "data": {}}) is None


def test_parse_webhook_event_with_attachment():
    payload = {
        "type": "new-message",
        "data": {
            "isFromMe": False,
            "text": "",
            "handle": {"address": "+15555550123"},
            "attachments": [{"guid": "abc-123"}],
        },
    }
    event = imessage_client.parse_webhook_event(payload)
    assert event["media_url"] == "/api/v1/attachment/abc-123/download"


def test_parse_webhook_event_missing_handle_returns_none():
    payload = {"type": "new-message", "data": {"isFromMe": False, "text": "hi"}}
    assert imessage_client.parse_webhook_event(payload) is None
