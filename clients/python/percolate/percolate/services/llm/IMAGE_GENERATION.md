# Image Generation Service

A clean utility for generating images using OpenAI's DALL-E API, integrated with the ModelRunner framework.

## Features

- **DALL-E 3** (default) and **DALL-E 2** support
- Automatic S3 storage with presigned URLs
- Base64 encoding option for direct client delivery
- SSE streaming-compatible markdown output
- Model-level configuration via `allow_generate_image`

## Usage

### 1. Enable Image Generation on a Model

Add `allow_generate_image: True` to your model's `model_config`:

```python
from percolate.models import AbstractModel

class MyAgent(AbstractModel):
    """An agent that can generate images"""

    model_config = {
        "allow_generate_image": True
    }
```

When `allow_generate_image` is enabled, the ModelRunner automatically adds the `generate_image` function as a tool.

### 2. Using Through the Agent

```python
import percolate as p8

agent = p8.Agent(MyAgent)
response = agent.run("Generate an image of a sunset over mountains")
```

The agent will:
1. Call the `generate_image` function
2. Upload the image to S3
3. Generate a presigned URL (valid for 1 hour)
4. Return markdown with the image link

### 3. Direct Usage (Without Agent)

```python
from percolate.services.llm.ImageGenerator import (
    ImageGenerator,
    generate_image,
    generate_and_save_to_s3,
    generate_as_base64
)

# Quick generation with URL
result = generate_image("A serene landscape")
image_url = result["data"][0]["url"]

# Generate and save to S3
result = generate_and_save_to_s3(
    prompt="A modern office",
    project_name="images",
    file_name="office.png"
)
s3_uri = result["s3_upload"]["uri"]

# Generate as base64 (for embedding)
base64_image = generate_as_base64("A cute cat")
```

### 4. Advanced Usage

```python
from percolate.services.llm.ImageGenerator import ImageGenerator

generator = ImageGenerator()

# High quality, large format
result = generator.generate_and_save_to_s3(
    prompt="A detailed architectural rendering",
    project_name="designs",
    file_name="building.png",
    size="1792x1024",  # Wide format
    quality="hd",       # High definition
    style="natural"     # Natural style
)
```

## ModelRunner Integration

When a model has `allow_generate_image: True`, the ModelRunner provides this function to the agent:

```python
def generate_image(
    prompt: str,
    size: str = "1024x1024",
    quality: str = "standard",
    style: str = "vivid"
) -> dict:
    """
    Generate an image from a text description using DALL-E 3.

    Args:
        prompt: Detailed text description of the image to generate
        size: Image dimensions - "1024x1024", "1024x1792", or "1792x1024"
        quality: Quality level - "standard" or "hd"
        style: Style of image - "vivid" or "natural"

    Returns:
        Dict with:
        - s3_uri: The S3 location of the image
        - presigned_url: A temporary URL to display the image (valid for 1 hour)
        - markdown: Ready-to-use markdown image syntax
        - image_info: Metadata about the generated image
    """
```

## Streaming Response

The function returns markdown that works perfectly with SSE streaming:

```json
{
  "status": "success",
  "s3_uri": "s3://bucket/user_123/images/generated_image_20250103_123456_abc123.png",
  "presigned_url": "https://s3.amazonaws.com/bucket/...",
  "markdown": "![Generated Image](https://s3.amazonaws.com/...)",
  "message": "Image generated successfully. You can display it using:\n![Generated Image](...)"
}
```

The agent can stream this markdown directly to the client, where it will render as an image.

## Configuration

### Environment Variables

```bash
# Required
OPENAI_API_KEY=sk-...

# S3 Configuration (see S3Service docs)
S3_ACCESS_KEY=...
S3_SECRET=...
S3_URL=...
S3_DEFAULT_BUCKET=percolate
```

### Model Parameters

**DALL-E 3** (default):
- Sizes: `1024x1024`, `1024x1792`, `1792x1024`
- Quality: `standard`, `hd`
- Style: `vivid`, `natural`
- Only supports n=1 (one image at a time)

**DALL-E 2**:
- Sizes: `256x256`, `512x512`, `1024x1024`
- Supports n=1-10 (multiple images)
- Quality/style parameters ignored

## Error Handling

The service includes comprehensive error handling:

```python
try:
    result = generator.generate_image("A cat")
except ImageGenerationError as e:
    print(f"Generation failed: {e}")
```

Errors are also gracefully handled in the ModelRunner integration:

```python
{
    "status": "error",
    "error": "API key not set",
    "message": "Failed to generate image: API key not set"
}
```

## Examples

See `examples/image_generation_example.py` for complete examples including:
1. Direct image generation
2. Agent-based generation
3. UserRoleAgent integration
4. Custom model configuration

## File Storage

Generated images are stored in S3 with the following structure:

```
s3://bucket/
  └── user_{user_id}/
      └── images/
          └── generated_image_{timestamp}_{hash}.png
```

For agents without user context:
```
s3://bucket/
  └── images/
      └── generated/
          └── generated_image_{timestamp}_{hash}.png
```

## Security

- **Presigned URLs** expire after 1 hour by default
- **User context** is respected (images stored in user-specific paths)
- **API keys** are only read from environment variables (never stored)
- **S3 access** follows your S3Service configuration

## Performance

- DALL-E 3 generation typically takes 10-30 seconds
- DALL-E 2 is faster (5-15 seconds)
- Images are automatically compressed as PNG
- Presigned URLs allow efficient image delivery without proxy overhead
