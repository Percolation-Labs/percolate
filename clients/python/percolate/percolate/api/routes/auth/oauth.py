"""
OAuth routes for authentication
"""

from typing import Optional
from fastapi import Request, Response, HTTPException, Header, Form
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse

from .router import router
from ...controllers.oauth import OAuthController
from percolate.api.auth.models import AuthRequest, TokenRequest, GrantType, AuthError
from percolate.utils import logger


# Get OAuth server from app state
def get_oauth_controller(request: Request) -> OAuthController:
    """Get OAuth controller from app state"""
    return OAuthController(request.app.state.oauth_server)


@router.get("/authorize")
async def authorize_get(
    request: Request,
    response_type: str = "code",
    client_id: str = None,
    redirect_uri: Optional[str] = None,
    scope: Optional[str] = None,
    state: Optional[str] = None,
    code_challenge: Optional[str] = None,
    code_challenge_method: Optional[str] = None,
    provider: Optional[str] = None,
    # Headers for bearer token auth
    authorization: Optional[str] = Header(None),
    x_user_email: Optional[str] = Header(None)
):
    """
    OAuth 2.1 Authorization endpoint (GET)
    
    Handles the authorization request and returns appropriate response
    """
    controller = get_oauth_controller(request)
    
    # Check for X_USER_EMAIL env var if header not provided
    if not x_user_email:
        import os
        x_user_email = os.environ.get("X_USER_EMAIL")
    
    try:
        # Build auth request
        auth_request = AuthRequest(
            response_type=response_type,
            client_id=client_id or "default-client",
            redirect_uri=redirect_uri,
            scope=scope,
            state=state,
            code_challenge=code_challenge,
            code_challenge_method=code_challenge_method,
            provider=provider
        )
        
        # Process authorization
        auth_response = await controller.process_authorization(
            auth_request,
            authorization,
            x_user_email
        )
        
        # Handle response
        if auth_response.redirect_uri:
            # Need to redirect (e.g., to Google)
            return RedirectResponse(url=auth_response.redirect_uri, status_code=302)
        
        elif auth_response.code and redirect_uri:
            # Have code, redirect back to client
            redirect_url = controller.build_redirect_url(
                redirect_uri,
                code=auth_response.code,
                state=state
            )
            return RedirectResponse(url=redirect_url, status_code=302)
        
        elif auth_response.code:
            # Return code in JSON (for non-browser flows)
            return JSONResponse({
                "code": auth_response.code,
                "state": state
            })
        
        else:
            # Show login form
            return HTMLResponse(controller.generate_login_html(auth_request))
    
    except AuthError as e:
        if redirect_uri:
            error_url = controller.build_redirect_url(
                redirect_uri,
                error=e.error,
                error_description=e.error_description,
                state=state
            )
            return RedirectResponse(url=error_url, status_code=302)
        else:
            raise HTTPException(status_code=e.status_code, detail={
                "error": e.error,
                "error_description": e.error_description
            })
    except Exception as e:
        logger.error(f"Authorization error: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/authorize")
async def authorize_post(
    request: Request,
    # Form data for login
    email: Optional[str] = Form(None),
    token: Optional[str] = Form(None),
    # Query params carried forward
    response_type: str = Form("code"),
    client_id: str = Form("default-client"),
    redirect_uri: Optional[str] = Form(None),
    scope: Optional[str] = Form(None),
    state: Optional[str] = Form(None),
    code_challenge: Optional[str] = Form(None),
    code_challenge_method: Optional[str] = Form(None),
    provider: Optional[str] = Form(None)
):
    """
    OAuth 2.1 Authorization endpoint (POST)
    
    Handles form submission for login
    """
    controller = get_oauth_controller(request)
    
    try:
        # Build auth request with credentials
        auth_request = AuthRequest(
            response_type=response_type,
            client_id=client_id,
            redirect_uri=redirect_uri,
            scope=scope,
            state=state,
            code_challenge=code_challenge,
            code_challenge_method=code_challenge_method,
            provider=provider or "bearer",
            bearer_token=token,
            user_email=email
        )
        
        # Process authorization
        auth_response = await controller.process_authorization(auth_request)
        
        # Redirect back with code
        if auth_response.code and redirect_uri:
            redirect_url = controller.build_redirect_url(
                redirect_uri,
                code=auth_response.code,
                state=state
            )
            return RedirectResponse(url=redirect_url, status_code=302)
        else:
            return JSONResponse({
                "code": auth_response.code,
                "state": state
            })
    
    except AuthError as e:
        # Show error on login form
        return HTMLResponse(controller.generate_login_html(
            auth_request,
            error=e.error_description or e.error
        ))
    except Exception as e:
        logger.error(f"Authorization error: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/token")
async def token_endpoint(
    request: Request,
    grant_type: str = Form(...),
    code: Optional[str] = Form(None),
    refresh_token: Optional[str] = Form(None),
    redirect_uri: Optional[str] = Form(None),
    client_id: Optional[str] = Form(None),
    client_secret: Optional[str] = Form(None),
    code_verifier: Optional[str] = Form(None),
    scope: Optional[str] = Form(None)
):
    """
    OAuth 2.1 Token endpoint
    
    Exchange authorization code or refresh token for access token
    """
    controller = get_oauth_controller(request)
    
    try:
        # Build token request
        token_request = TokenRequest(
            grant_type=GrantType(grant_type),
            code=code,
            refresh_token=refresh_token,
            redirect_uri=redirect_uri,
            client_id=client_id,
            client_secret=client_secret,
            code_verifier=code_verifier,
            scope=scope
        )
        
        # Process token request
        token_response = await controller.exchange_token(token_request)
        
        return JSONResponse(token_response.model_dump(exclude_none=True))
    
    except AuthError as e:
        raise HTTPException(status_code=e.status_code, detail={
            "error": e.error,
            "error_description": e.error_description
        })
    except Exception as e:
        logger.error(f"Token error: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/revoke")
async def revoke_token(
    request: Request,
    token: str = Form(...),
    token_type_hint: Optional[str] = Form(None)
):
    """
    OAuth 2.1 Token Revocation endpoint
    """
    controller = get_oauth_controller(request)
    
    try:
        await controller.revoke_token(token, token_type_hint)
        return Response(status_code=200)  # Always return 200 per spec
    except Exception as e:
        logger.error(f"Revocation error: {e}")
        return Response(status_code=200)  # Still return 200 per spec


@router.post("/introspect")
async def introspect_token(
    request: Request,
    token: str = Form(...),
    token_type_hint: Optional[str] = Form(None)
):
    """
    OAuth 2.1 Token Introspection endpoint
    """
    controller = get_oauth_controller(request)
    
    result = await controller.introspect_token(token, token_type_hint)
    return JSONResponse(result)


@router.post("/register")
async def register_client(request: Request):
    """
    Dynamic client registration endpoint
    
    For MCP clients, we accept any registration and map to our internal client
    """
    try:
        data = await request.json()
        
        # Accept any client registration
        # In a real implementation, you'd validate and store client details
        return JSONResponse({
            "client_id": data.get("client_id", "mcp-client"),
            "client_secret": None,  # Public client
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "redirect_uris": data.get("redirect_uris", []),
            "token_endpoint_auth_method": "none",
            "scope": "read write"
        })
    except Exception as e:
        logger.error(f"Client registration error: {e}")
        raise HTTPException(status_code=400, detail=str(e))