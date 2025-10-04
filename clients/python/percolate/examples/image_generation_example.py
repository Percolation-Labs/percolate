"""
Example demonstrating image generation with the ModelRunner.

This example shows how to:
1. Use allow_generate_image in model_config to enable image generation
2. Generate images through the ModelRunner's generate_image function
3. Get presigned URLs for displaying images in chat
"""

import percolate as p8
from percolate.models import AbstractModel


# Example 1: Simple model with image generation enabled
class ImageArtist(AbstractModel):
    """An AI artist that can generate images from descriptions"""

    model_config = {"allow_generate_image": True}

    @classmethod
    def get_model_description(cls):
        return """You are a creative AI artist. You can generate images based on user descriptions.
        When a user asks you to create or generate an image, use the generate_image function.
        Always provide the markdown link so the user can see the image."""


# Example 2: Using the image generation directly
def direct_image_generation_example():
    """Example of direct usage without an agent"""
    from percolate.services.llm.ImageGenerator import ImageGenerator
    from percolate.services.S3Service import S3Service

    # Initialize services
    generator = ImageGenerator()
    s3 = S3Service()

    # Generate and save to S3
    result = generator.generate_and_save_to_s3(
        prompt="A serene mountain landscape at sunset with a lake reflection",
        project_name="examples",
        file_name="mountain_sunset.png"
    )

    # Get presigned URL
    presigned_url = s3.get_presigned_url_for_uri(
        s3_uri=result["s3_upload"]["uri"],
        expires_in=3600
    )

    print(f"Image generated!")
    print(f"S3 URI: {result['s3_upload']['uri']}")
    print(f"Presigned URL: {presigned_url}")
    print(f"Markdown: ![Generated Image]({presigned_url})")


# Example 3: Using through the agent
def agent_image_generation_example():
    """Example of using image generation through an agent"""

    # Create an agent with image generation enabled
    agent = p8.Agent(ImageArtist)

    # The agent can now use generate_image as a tool
    response = agent.run(
        "Please create an image of a futuristic city with flying cars at night"
    )

    print(response)


# Example 4: UserRoleAgent with image generation (already configured)
def user_role_agent_example():
    """Example using the UserRoleAgent which has image generation enabled"""
    from percolate.models.p8.types import UserRoleAgent

    agent = p8.Agent(UserRoleAgent)

    # The agent will automatically have access to generate_image
    response = agent.run(
        "Generate an image of a cozy coffee shop interior with warm lighting"
    )

    print(response)


if __name__ == "__main__":
    print("=" * 60)
    print("Image Generation Examples")
    print("=" * 60)

    print("\n1. Direct Image Generation (no agent)")
    print("-" * 60)
    direct_image_generation_example()

    print("\n2. Agent-based Image Generation")
    print("-" * 60)
    agent_image_generation_example()

    print("\n3. UserRoleAgent with Image Generation")
    print("-" * 60)
    user_role_agent_example()
