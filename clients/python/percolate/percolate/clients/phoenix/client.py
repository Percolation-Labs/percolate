"""Phoenix client for sending trace annotations via REST API."""

from uuid import UUID
from typing import Optional

import httpx
from pydantic import BaseModel

from percolate.utils import logger


class PhoenixAnnotation(BaseModel):
    """Annotation data for Phoenix traces."""

    trace_id: str
    span_id: str
    name: str
    annotator_kind: str = "HUMAN"
    result: dict[str, Optional[str | float]]
    metadata: Optional[dict[str, str]] = None


class PhoenixClient:
    """Client for sending annotations to Phoenix."""

    def __init__(self, base_url: str) -> None:
        """
        Initialize Phoenix client.

        Args:
            base_url: Base URL for Phoenix API (e.g., http://localhost:6006)
        """
        self.base_url = str(base_url).rstrip("/")
        self.annotations_endpoint = f"{self.base_url}/v1/span_annotations"
        self.spans_endpoint = f"{self.base_url}/v1/spans"

    async def send_annotation(self, annotation: PhoenixAnnotation) -> bool:
        """
        Send an annotation to Phoenix.

        Args:
            annotation: PhoenixAnnotation containing trace metadata and feedback

        Returns:
            True if successful, False otherwise
        """
        try:
            async with httpx.AsyncClient(timeout=5.0) as client:
                payload = {"data": [annotation.model_dump(mode="json")]}
                response = await client.post(
                    self.annotations_endpoint,
                    json=payload,
                )
                response.raise_for_status()
                logger.info(f"Successfully sent annotation to Phoenix for trace {annotation.trace_id}")
                return True
        except httpx.HTTPStatusError as e:
            logger.warning(
                f"Failed to send annotation to Phoenix: {e}. "
                f"Response body: {e.response.text if hasattr(e, 'response') else 'N/A'}"
            )
            return False
        except httpx.HTTPError as e:
            logger.warning(f"Failed to send annotation to Phoenix: {e}")
            return False
        except Exception:
            logger.exception("Unexpected error sending annotation to Phoenix")
            return False

    async def send_feedback_annotation(
        self,
        trace_id: str | UUID,
        span_id: Optional[str],
        session_id: str,
        feedback_approved: bool,
        user_id: Optional[str] = None,
        feedback_note: Optional[str] = None,
        feedback_tags: Optional[list[str]] = None,
    ) -> bool:
        """
        Send a feedback annotation to Phoenix for a traced session.

        Args:
            trace_id: UUID object or hex string of the trace
            span_id: Optional span ID from OTEL context (hex string)
            session_id: Session ID being annotated
            feedback_approved: True for thumbs up, False for thumbs down
            user_id: Optional user ID providing feedback
            feedback_note: Optional feedback explanation text
            feedback_tags: Optional list of tags/labels

        Returns:
            True if annotation was successfully sent, False otherwise
        """
        # Convert trace_id UUID to hex string
        trace_id_hex = format(trace_id.int, "032x") if isinstance(trace_id, UUID) else trace_id

        # Use provided span_id or generate fallback
        if not span_id:
            # Fallback: use a deterministic span ID based on session ID
            span_id = format(int(str(session_id).replace("-", "")[:16], 16), "016x")
            logger.debug(f"No active span, using fallback span_id: {span_id}")

        # Build annotation result
        result = {
            "label": "positive" if feedback_approved else "negative",
            "score": 1.0 if feedback_approved else 0.0,
            "explanation": feedback_note,
        }

        metadata = {
            "session_id": session_id,
        }
        if user_id:
            metadata["user_id"] = user_id
        if feedback_tags:
            metadata["tags"] = ",".join(feedback_tags)

        annotation = PhoenixAnnotation(
            trace_id=trace_id_hex,
            span_id=span_id,
            name=f"user_feedback_{'positive' if feedback_approved else 'negative'}",
            annotator_kind="HUMAN",
            result=result,
            metadata=metadata,
        )

        success = await self.send_annotation(annotation)
        if success:
            logger.info(f"Successfully sent feedback annotation to Phoenix for session {session_id}")
        else:
            logger.warning(f"Failed to send feedback annotation to Phoenix for session {session_id}")

        return success
