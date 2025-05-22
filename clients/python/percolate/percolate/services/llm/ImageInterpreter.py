"""
Image Interpreter service for analyzing images using LLM vision models.
Supports OpenAI GPT-4 Vision and can be extended for other providers like Gemini.
"""

import os
import json
import tempfile
import base64
from typing import List, Dict, Any, Optional, Union
from pathlib import Path
from PIL import Image
import requests

from percolate.utils import logger


class ImageInterpreter:
    """
    Service for interpreting images using LLM vision models.
    Currently supports OpenAI GPT-4 Vision, extensible to other providers.
    """
    
    def __init__(self, provider: str = "openai", api_key: Optional[str] = None):
        """
        Initialize the image interpreter.
        
        Args:
            provider: Vision model provider ("openai", "gemini", etc.)
            api_key: API key for the provider. If not provided, will try to get from environment.
        """
        self.provider = provider.lower()
        self.api_key = api_key or self._get_api_key()
        self.base_url = self._get_base_url()
        
    def _get_api_key(self) -> Optional[str]:
        """Get API key from environment or service."""
        if self.provider == "openai":
            # Try environment variable first
            api_key = os.environ.get("OPENAI_API_KEY")
            if api_key:
                return api_key
                
            # Try the existing service method
            try:
                from percolate.services.llm.LanguageModel import try_get_open_ai_key
                return try_get_open_ai_key()
            except ImportError:
                logger.warning("Could not import OpenAI key function")
                return None
        elif self.provider == "gemini":
            return os.environ.get("GOOGLE_API_KEY")
        else:
            logger.warning(f"Unknown provider: {self.provider}")
            return None
    
    def _get_base_url(self) -> str:
        """Get base URL for the provider."""
        if self.provider == "openai":
            return "https://api.openai.com/v1/chat/completions"
        elif self.provider == "gemini":
            return "https://generativelanguage.googleapis.com/v1beta/models/gemini-pro-vision:generateContent"
        else:
            raise ValueError(f"Unsupported provider: {self.provider}")
    
    def is_available(self) -> bool:
        """Check if the image interpreter service is available (API key present)."""
        return self.api_key is not None
    
    def describe_images(
        self,
        images: Union[str, List[str], Image.Image, List[Image.Image]],
        prompt: str = "Describe the image you see in detail",
        context: Optional[str] = None,
        response_format: str = "text",
        max_tokens: int = 3000,
        **kwargs
    ) -> Dict[str, Any]:
        """
        Describe one or more images using the vision model.
        
        Args:
            images: Image(s) to analyze (file paths, URLs, or PIL Images)
            prompt: Prompt/question about the image(s)
            context: Optional context for interpretation
            response_format: "text" or "json"
            max_tokens: Maximum tokens in response
            **kwargs: Additional provider-specific parameters
            
        Returns:
            Dict containing the interpretation results
            
        Raises:
            ValueError: If API key is not available
            Exception: If interpretation fails
        """
        if not self.is_available():
            raise ValueError(f"{self.provider.upper()} API key not available for image interpretation")
        
        # Normalize images to list
        if not isinstance(images, list):
            images = [images]
        
        # Process images to base64 or URLs
        processed_images = []
        for image in images:
            processed_images.append(self._process_image(image))
        
        logger.info(f"Describing {len(processed_images)} images using {self.provider}")
        
        if self.provider == "openai":
            return self._describe_with_openai(
                processed_images, prompt, context, response_format, max_tokens, **kwargs
            )
        elif self.provider == "gemini":
            return self._describe_with_gemini(
                processed_images, prompt, context, response_format, max_tokens, **kwargs
            )
        else:
            raise ValueError(f"Unsupported provider: {self.provider}")
    
    def _process_image(self, image: Union[str, Image.Image]) -> Dict[str, Any]:
        """
        Process an image into the format needed by the vision model.
        
        Args:
            image: Image to process (file path, URL, or PIL Image)
            
        Returns:
            Dict with image data (base64 or URL)
        """
        if isinstance(image, str):
            if image.startswith(('http://', 'https://')):
                # It's a URL
                return {"type": "url", "data": image}
            else:
                # It's a file path
                with open(image, "rb") as f:
                    image_data = f.read()
                base64_image = base64.b64encode(image_data).decode('utf-8')
                
                # Detect image format
                ext = Path(image).suffix.lower()
                mime_type = self._get_mime_type(ext)
                
                return {
                    "type": "base64",
                    "data": f"data:{mime_type};base64,{base64_image}",
                    "format": ext
                }
        elif isinstance(image, Image.Image):
            # Convert PIL Image to base64
            with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as temp_file:
                image.save(temp_file.name, format="PNG")
                with open(temp_file.name, "rb") as f:
                    image_data = f.read()
                os.unlink(temp_file.name)
                
            base64_image = base64.b64encode(image_data).decode('utf-8')
            return {
                "type": "base64", 
                "data": f"data:image/png;base64,{base64_image}",
                "format": ".png"
            }
        else:
            raise ValueError(f"Unsupported image type: {type(image)}")
    
    def _get_mime_type(self, ext: str) -> str:
        """Get MIME type for image extension."""
        mime_types = {
            '.png': 'image/png',
            '.jpg': 'image/jpeg',
            '.jpeg': 'image/jpeg',
            '.gif': 'image/gif',
            '.bmp': 'image/bmp',
            '.tiff': 'image/tiff',
            '.webp': 'image/webp'
        }
        return mime_types.get(ext.lower(), 'image/png')
    
    def _describe_with_openai(
        self,
        processed_images: List[Dict[str, Any]],
        prompt: str,
        context: Optional[str],
        response_format: str,
        max_tokens: int,
        **kwargs
    ) -> Dict[str, Any]:
        """Describe images using OpenAI GPT-4 Vision."""
        
        # Build system prompt
        system_prompt = "You are an expert at analyzing and describing images in great detail."
        if context:
            system_prompt += f" Context: {context}"
        
        # Build user content with text and images
        user_content = [{"type": "text", "text": prompt}]
        
        for i, img in enumerate(processed_images):
            if img["type"] == "url":
                user_content.append({
                    "type": "image_url",
                    "image_url": {"url": img["data"]}
                })
            else:  # base64
                user_content.append({
                    "type": "image_url", 
                    "image_url": {"url": img["data"]}
                })
        
        # Prepare request
        headers = {
            "Authorization": f"Bearer {self.api_key}",
            "Content-Type": "application/json"
        }
        
        # Import here to avoid circular imports
        from percolate.utils.env import P8_DEFAULT_VISION_MODEL
        
        payload = {
            "model": kwargs.get("model", P8_DEFAULT_VISION_MODEL),
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_content}
            ],
            "max_tokens": max_tokens
        }
        
        # Add response format if JSON requested
        if response_format == "json":
            payload["response_format"] = {"type": "json_object"}
        
        try:
            response = requests.post(self.base_url, headers=headers, json=payload, timeout=120)
            
            if response.status_code == 200:
                result = response.json()
                content = result["choices"][0]["message"]["content"]
                
                # Parse JSON if requested
                if response_format == "json":
                    try:
                        content = json.loads(content)
                    except json.JSONDecodeError:
                        logger.warning("Failed to parse JSON response, returning as text")
                
                return {
                    "success": True,
                    "provider": "openai",
                    "content": content,
                    "usage": result.get("usage", {}),
                    "model": result["model"],
                    "images_processed": len(processed_images)
                }
            else:
                error_msg = f"OpenAI API error: {response.status_code} - {response.text}"
                logger.error(error_msg)
                return {
                    "success": False,
                    "error": error_msg,
                    "provider": "openai"
                }
                
        except requests.exceptions.RequestException as e:
            error_msg = f"Request failed: {str(e)}"
            logger.error(error_msg)
            return {
                "success": False,
                "error": error_msg,
                "provider": "openai"
            }
    
    def _describe_with_gemini(
        self,
        processed_images: List[Dict[str, Any]],
        prompt: str,
        context: Optional[str],
        response_format: str,
        max_tokens: int,
        **kwargs
    ) -> Dict[str, Any]:
        """Describe images using Google Gemini Vision (placeholder for future implementation)."""
        # TODO: Implement Gemini Vision API integration
        raise NotImplementedError("Gemini provider not yet implemented")


# Global image interpreter instance
_image_interpreter = None

def get_image_interpreter(provider: str = "openai") -> ImageInterpreter:
    """Get a global image interpreter instance."""
    global _image_interpreter
    if _image_interpreter is None or _image_interpreter.provider != provider:
        _image_interpreter = ImageInterpreter(provider=provider)
    return _image_interpreter