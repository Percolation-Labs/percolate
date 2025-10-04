"""
Image generation service using OpenAI's DALL-E API.

This service provides utilities for generating images from text prompts
and handling the results (saving to S3 or returning as base64).
"""

import os
import base64
import typing
from io import BytesIO
import requests
from percolate.utils import logger


class ImageGenerationError(Exception):
    """Raised when image generation fails"""
    pass


class ImageGenerator:
    """
    Utility service for generating images using OpenAI's DALL-E API.

    Supports:
    - DALL-E 3 (default, highest quality)
    - DALL-E 2 (faster, more affordable)
    - Multiple output formats (URL, base64, S3)
    - Various size and quality options
    """

    # Model constants
    DALLE_3 = "dall-e-3"
    DALLE_2 = "dall-e-2"

    # Size options for DALL-E 3
    SIZES_DALLE_3 = ["1024x1024", "1024x1792", "1792x1024"]
    # Size options for DALL-E 2
    SIZES_DALLE_2 = ["256x256", "512x512", "1024x1024"]

    # Quality options (DALL-E 3 only)
    QUALITY_STANDARD = "standard"
    QUALITY_HD = "hd"

    # Style options (DALL-E 3 only)
    STYLE_VIVID = "vivid"
    STYLE_NATURAL = "natural"

    def __init__(self, api_key: str = None):
        """
        Initialize the image generator.

        Args:
            api_key: OpenAI API key. If not provided, will use OPENAI_API_KEY env var
        """
        self.api_key = api_key or os.environ.get("OPENAI_API_KEY")
        if not self.api_key:
            raise ValueError(
                "OpenAI API key is required. Set OPENAI_API_KEY environment variable "
                "or pass api_key parameter."
            )

        self.base_url = "https://api.openai.com/v1/images/generations"

    def generate_image(
        self,
        prompt: str,
        model: str = DALLE_3,
        size: str = "1024x1024",
        quality: str = QUALITY_STANDARD,
        style: str = STYLE_VIVID,
        n: int = 1,
        response_format: str = "url"
    ) -> typing.Dict[str, typing.Any]:
        """
        Generate an image from a text prompt using DALL-E.

        Args:
            prompt: Text description of the desired image
            model: Model to use (DALLE_3 or DALLE_2)
            size: Image dimensions. For DALL-E 3: 1024x1024, 1024x1792, or 1792x1024.
                  For DALL-E 2: 256x256, 512x512, or 1024x1024
            quality: Quality level - "standard" or "hd" (DALL-E 3 only)
            style: Style of image - "vivid" or "natural" (DALL-E 3 only)
            n: Number of images to generate (1-10 for DALL-E 2, must be 1 for DALL-E 3)
            response_format: "url" or "b64_json"

        Returns:
            Dict with generation results containing:
            - data: List of generated images (URLs or base64)
            - model: Model used
            - created: Timestamp

        Raises:
            ImageGenerationError: If generation fails
        """
        # Validate inputs
        if model == self.DALLE_3:
            if size not in self.SIZES_DALLE_3:
                raise ValueError(
                    f"Invalid size for DALL-E 3. Must be one of: {self.SIZES_DALLE_3}"
                )
            if n != 1:
                raise ValueError("DALL-E 3 only supports n=1")
        elif model == self.DALLE_2:
            if size not in self.SIZES_DALLE_2:
                raise ValueError(
                    f"Invalid size for DALL-E 2. Must be one of: {self.SIZES_DALLE_2}"
                )
            if quality != self.QUALITY_STANDARD or style != self.STYLE_VIVID:
                logger.warning(
                    "Quality and style parameters are ignored for DALL-E 2"
                )
        else:
            raise ValueError(f"Invalid model: {model}. Use DALLE_3 or DALLE_2")

        if response_format not in ["url", "b64_json"]:
            raise ValueError("response_format must be 'url' or 'b64_json'")

        # Build request payload
        payload = {
            "model": model,
            "prompt": prompt,
            "n": n,
            "size": size,
            "response_format": response_format
        }

        # Add DALL-E 3 specific parameters
        if model == self.DALLE_3:
            payload["quality"] = quality
            payload["style"] = style

        # Make API request
        headers = {
            "Authorization": f"Bearer {self.api_key}",
            "Content-Type": "application/json"
        }

        logger.info(f"Generating image with {model}: {prompt[:100]}...")

        try:
            response = requests.post(
                self.base_url,
                json=payload,
                headers=headers,
                timeout=120  # DALL-E can take time
            )
            response.raise_for_status()

            result = response.json()
            logger.info(f"Successfully generated {len(result['data'])} image(s)")

            return result

        except requests.exceptions.HTTPError as e:
            error_detail = e.response.json() if e.response else str(e)
            logger.error(f"Image generation failed: {error_detail}")
            raise ImageGenerationError(
                f"Failed to generate image: {error_detail}"
            ) from e
        except Exception as e:
            logger.error(f"Unexpected error during image generation: {str(e)}")
            raise ImageGenerationError(
                f"Unexpected error: {str(e)}"
            ) from e

    def generate_and_save_to_s3(
        self,
        prompt: str,
        s3_uri: str = None,
        project_name: str = None,
        file_name: str = None,
        model: str = DALLE_3,
        size: str = "1024x1024",
        quality: str = QUALITY_STANDARD,
        style: str = STYLE_VIVID
    ) -> typing.Dict[str, typing.Any]:
        """
        Generate an image and save it directly to S3.

        Args:
            prompt: Text description of the desired image
            s3_uri: Full S3 URI (e.g., s3://bucket/path/file.png). If provided,
                    project_name and file_name are ignored
            project_name: Project name for S3 path (used if s3_uri not provided)
            file_name: File name for S3 (used if s3_uri not provided)
            model: Model to use (DALLE_3 or DALLE_2)
            size: Image dimensions
            quality: Quality level (DALL-E 3 only)
            style: Style of image (DALL-E 3 only)

        Returns:
            Dict with S3 upload result and image metadata

        Raises:
            ImageGenerationError: If generation or upload fails
            ValueError: If neither s3_uri nor (project_name and file_name) are provided
        """
        from percolate.services.S3Service import S3Service

        # Validate S3 parameters
        if not s3_uri and not (project_name and file_name):
            raise ValueError(
                "Either s3_uri or both project_name and file_name must be provided"
            )

        # Generate image as URL first
        result = self.generate_image(
            prompt=prompt,
            model=model,
            size=size,
            quality=quality,
            style=style,
            n=1,
            response_format="url"
        )

        # Download the image
        image_url = result["data"][0]["url"]
        logger.info(f"Downloading generated image from {image_url}")

        try:
            image_response = requests.get(image_url, timeout=60)
            image_response.raise_for_status()
            image_bytes = image_response.content

        except Exception as e:
            logger.error(f"Failed to download generated image: {str(e)}")
            raise ImageGenerationError(
                f"Failed to download image: {str(e)}"
            ) from e

        # Upload to S3
        s3 = S3Service()

        try:
            if s3_uri:
                # Use direct URI upload
                upload_result = s3.upload_filebytes_to_uri(
                    s3_uri=s3_uri,
                    file_content=image_bytes,
                    content_type="image/png"
                )
            else:
                # Use project-based upload
                upload_result = s3.upload_file(
                    project_name=project_name,
                    file_name=file_name,
                    file_content=image_bytes,
                    content_type="image/png"
                )

            logger.info(f"Image uploaded to S3: {upload_result.get('uri')}")

            return {
                "generation": result,
                "s3_upload": upload_result,
                "prompt": prompt,
                "model": model,
                "size": size
            }

        except Exception as e:
            logger.error(f"Failed to upload image to S3: {str(e)}")
            raise ImageGenerationError(
                f"Failed to upload to S3: {str(e)}"
            ) from e

    def generate_as_base64(
        self,
        prompt: str,
        model: str = DALLE_3,
        size: str = "1024x1024",
        quality: str = QUALITY_STANDARD,
        style: str = STYLE_VIVID
    ) -> typing.Dict[str, typing.Any]:
        """
        Generate an image and return it as base64-encoded data.

        This is useful for sending images directly to clients without S3.

        Args:
            prompt: Text description of the desired image
            model: Model to use (DALLE_3 or DALLE_2)
            size: Image dimensions
            quality: Quality level (DALL-E 3 only)
            style: Style of image (DALL-E 3 only)

        Returns:
            Dict with:
            - b64_json: Base64-encoded image data
            - prompt: Original prompt
            - model: Model used
            - size: Image size
            - revised_prompt: Revised prompt (DALL-E 3 only)
        """
        result = self.generate_image(
            prompt=prompt,
            model=model,
            size=size,
            quality=quality,
            style=style,
            n=1,
            response_format="b64_json"
        )

        image_data = result["data"][0]

        return {
            "b64_json": image_data["b64_json"],
            "prompt": prompt,
            "revised_prompt": image_data.get("revised_prompt"),
            "model": model,
            "size": size
        }


# Convenience functions for common use cases

def generate_image(
    prompt: str,
    model: str = ImageGenerator.DALLE_3,
    size: str = "1024x1024",
    api_key: str = None
) -> typing.Dict[str, typing.Any]:
    """
    Quick function to generate an image with default settings.

    Args:
        prompt: Text description of the desired image
        model: Model to use (default: DALL-E 3)
        size: Image dimensions (default: 1024x1024)
        api_key: OpenAI API key (optional, uses env var if not provided)

    Returns:
        Generation result with image URL(s)
    """
    generator = ImageGenerator(api_key=api_key)
    return generator.generate_image(prompt=prompt, model=model, size=size)


def generate_and_save_to_s3(
    prompt: str,
    s3_uri: str = None,
    project_name: str = None,
    file_name: str = None,
    api_key: str = None
) -> typing.Dict[str, typing.Any]:
    """
    Quick function to generate an image and save to S3.

    Args:
        prompt: Text description of the desired image
        s3_uri: Full S3 URI (optional)
        project_name: Project name for S3 path (optional)
        file_name: File name for S3 (optional)
        api_key: OpenAI API key (optional, uses env var if not provided)

    Returns:
        Dict with generation and upload results
    """
    generator = ImageGenerator(api_key=api_key)
    return generator.generate_and_save_to_s3(
        prompt=prompt,
        s3_uri=s3_uri,
        project_name=project_name,
        file_name=file_name
    )


def generate_as_base64(
    prompt: str,
    api_key: str = None
) -> str:
    """
    Quick function to generate an image and return as base64.

    Args:
        prompt: Text description of the desired image
        api_key: OpenAI API key (optional, uses env var if not provided)

    Returns:
        Base64-encoded image data
    """
    generator = ImageGenerator(api_key=api_key)
    result = generator.generate_as_base64(prompt=prompt)
    return result["b64_json"]
