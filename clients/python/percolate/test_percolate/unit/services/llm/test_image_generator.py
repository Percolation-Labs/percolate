"""
Unit tests for ImageGenerator service.

Tests the image generation functionality with mocked OpenAI and S3 responses.
"""

import pytest
from unittest.mock import Mock, patch, MagicMock
from percolate.services.llm.ImageGenerator import (
    ImageGenerator,
    ImageGenerationError,
    generate_image,
    generate_and_save_to_s3,
    generate_as_base64
)


class TestImageGenerator:
    """Test cases for ImageGenerator class"""

    @pytest.fixture
    def mock_openai_response(self):
        """Mock successful OpenAI API response"""
        return {
            "created": 1234567890,
            "data": [
                {
                    "url": "https://example.com/generated-image.png",
                    "revised_prompt": "A beautiful sunset over mountains with vibrant colors"
                }
            ]
        }

    @pytest.fixture
    def mock_openai_response_b64(self):
        """Mock successful OpenAI API response with base64"""
        return {
            "created": 1234567890,
            "data": [
                {
                    "b64_json": "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==",
                    "revised_prompt": "A beautiful sunset over mountains with vibrant colors"
                }
            ]
        }

    @pytest.fixture
    def generator(self):
        """Create a generator with a mock API key"""
        with patch.dict('os.environ', {'OPENAI_API_KEY': 'test-key'}):
            return ImageGenerator()

    def test_initialization_with_api_key(self):
        """Test that generator initializes with API key"""
        gen = ImageGenerator(api_key="test-key")
        assert gen.api_key == "test-key"

    def test_initialization_from_env(self):
        """Test that generator reads API key from environment"""
        with patch.dict('os.environ', {'OPENAI_API_KEY': 'env-key'}):
            gen = ImageGenerator()
            assert gen.api_key == "env-key"

    def test_initialization_fails_without_api_key(self):
        """Test that initialization fails without API key"""
        with patch.dict('os.environ', {}, clear=True):
            with pytest.raises(ValueError, match="OpenAI API key is required"):
                ImageGenerator()

    @patch('requests.post')
    def test_generate_image_success(self, mock_post, generator, mock_openai_response):
        """Test successful image generation"""
        # Mock the requests.post response
        mock_response = Mock()
        mock_response.status_code = 200
        mock_response.json.return_value = mock_openai_response
        mock_post.return_value = mock_response

        # Generate image
        result = generator.generate_image(
            prompt="A sunset over mountains",
            model=ImageGenerator.DALLE_3,
            size="1024x1024"
        )

        # Verify result
        assert result == mock_openai_response
        assert len(result["data"]) == 1
        assert "url" in result["data"][0]

        # Verify API was called correctly
        mock_post.assert_called_once()
        call_args = mock_post.call_args
        assert call_args[0][0] == "https://api.openai.com/v1/images/generations"

        # Check payload
        payload = call_args[1]["json"]
        assert payload["prompt"] == "A sunset over mountains"
        assert payload["model"] == "dall-e-3"
        assert payload["size"] == "1024x1024"

    @patch('requests.post')
    def test_generate_image_with_b64_format(self, mock_post, generator, mock_openai_response_b64):
        """Test image generation with base64 format"""
        mock_response = Mock()
        mock_response.status_code = 200
        mock_response.json.return_value = mock_openai_response_b64
        mock_post.return_value = mock_response

        result = generator.generate_image(
            prompt="A cat",
            response_format="b64_json"
        )

        assert "b64_json" in result["data"][0]

        # Verify format in payload
        payload = mock_post.call_args[1]["json"]
        assert payload["response_format"] == "b64_json"

    def test_invalid_dalle3_size(self, generator):
        """Test that invalid DALL-E 3 size raises error"""
        with pytest.raises(ValueError, match="Invalid size for DALL-E 3"):
            generator.generate_image(
                prompt="Test",
                model=ImageGenerator.DALLE_3,
                size="512x512"  # Invalid for DALL-E 3
            )

    def test_invalid_dalle3_n_parameter(self, generator):
        """Test that n>1 raises error for DALL-E 3"""
        with pytest.raises(ValueError, match="DALL-E 3 only supports n=1"):
            generator.generate_image(
                prompt="Test",
                model=ImageGenerator.DALLE_3,
                n=2
            )

    def test_invalid_dalle2_size(self, generator):
        """Test that invalid DALL-E 2 size raises error"""
        with pytest.raises(ValueError, match="Invalid size for DALL-E 2"):
            generator.generate_image(
                prompt="Test",
                model=ImageGenerator.DALLE_2,
                size="1792x1024"  # Invalid for DALL-E 2
            )

    @patch('requests.post')
    def test_api_error_handling(self, mock_post, generator):
        """Test handling of API errors"""
        # Mock failed response
        mock_response = Mock()
        mock_response.status_code = 400
        mock_response.json.return_value = {"error": {"message": "Invalid prompt"}}
        mock_response.raise_for_status.side_effect = Exception("Bad Request")
        mock_post.return_value = mock_response

        with pytest.raises(ImageGenerationError, match="Unexpected error"):
            generator.generate_image(prompt="Test")

    @patch('requests.post')
    @patch('requests.get')
    def test_generate_and_save_to_s3(
        self,
        mock_get,
        mock_post,
        generator,
        mock_openai_response
    ):
        """Test generating and saving to S3"""
        # Mock OpenAI response
        mock_post_response = Mock()
        mock_post_response.status_code = 200
        mock_post_response.json.return_value = mock_openai_response
        mock_post.return_value = mock_post_response

        # Mock image download
        mock_get_response = Mock()
        mock_get_response.status_code = 200
        mock_get_response.content = b"fake-image-data"
        mock_get.return_value = mock_get_response

        # Mock S3 service
        with patch('percolate.services.S3Service.S3Service') as mock_s3_class:
            mock_s3 = Mock()
            mock_s3.upload_file.return_value = {
                "uri": "s3://bucket/images/test.png",
                "status": "success"
            }
            mock_s3_class.return_value = mock_s3

            result = generator.generate_and_save_to_s3(
                prompt="Test image",
                project_name="test-project",
                file_name="test.png"
            )

            # Verify result structure
            assert result["generation"] == mock_openai_response
            assert "s3_upload" in result
            assert result["s3_upload"]["uri"] == "s3://bucket/images/test.png"
            assert result["prompt"] == "Test image"

            # Verify S3 upload was called
            mock_s3.upload_file.assert_called_once()
            call_kwargs = mock_s3.upload_file.call_args[1]
            assert call_kwargs["project_name"] == "test-project"
            assert call_kwargs["file_name"] == "test.png"
            assert call_kwargs["content_type"] == "image/png"

    @patch('requests.post')
    def test_generate_as_base64(self, mock_post, generator, mock_openai_response_b64):
        """Test generating image as base64"""
        mock_response = Mock()
        mock_response.status_code = 200
        mock_response.json.return_value = mock_openai_response_b64
        mock_post.return_value = mock_response

        result = generator.generate_as_base64(prompt="Test cat")

        assert "b64_json" in result
        assert result["b64_json"] == mock_openai_response_b64["data"][0]["b64_json"]
        assert result["prompt"] == "Test cat"
        assert "revised_prompt" in result

    @patch('percolate.services.llm.ImageGenerator.ImageGenerator.generate_image')
    def test_convenience_function_generate_image(self, mock_generate):
        """Test the convenience function for generating images"""
        mock_generate.return_value = {"data": [{"url": "test-url"}]}

        with patch.dict('os.environ', {'OPENAI_API_KEY': 'test-key'}):
            result = generate_image("A test image")

        assert result["data"][0]["url"] == "test-url"

    @patch('percolate.services.llm.ImageGenerator.ImageGenerator.generate_and_save_to_s3')
    def test_convenience_function_save_to_s3(self, mock_save):
        """Test the convenience function for saving to S3"""
        mock_save.return_value = {
            "s3_upload": {"uri": "s3://test"},
            "generation": {"data": []}
        }

        with patch.dict('os.environ', {'OPENAI_API_KEY': 'test-key'}):
            result = generate_and_save_to_s3(
                "Test",
                project_name="test",
                file_name="test.png"
            )

        assert result["s3_upload"]["uri"] == "s3://test"

    @patch('percolate.services.llm.ImageGenerator.ImageGenerator.generate_as_base64')
    def test_convenience_function_base64(self, mock_b64):
        """Test the convenience function for base64 generation"""
        mock_b64.return_value = {"b64_json": "base64-data"}

        with patch.dict('os.environ', {'OPENAI_API_KEY': 'test-key'}):
            result = generate_as_base64("Test")

        assert result == "base64-data"

    def test_dalle3_parameters(self, generator):
        """Test that DALL-E 3 specific parameters are validated"""
        with patch('requests.post') as mock_post:
            mock_response = Mock()
            mock_response.status_code = 200
            mock_response.json.return_value = {"data": [{"url": "test"}]}
            mock_post.return_value = mock_response

            generator.generate_image(
                prompt="Test",
                model=ImageGenerator.DALLE_3,
                quality="hd",
                style="natural"
            )

            payload = mock_post.call_args[1]["json"]
            assert payload["quality"] == "hd"
            assert payload["style"] == "natural"

    def test_dalle2_ignores_quality_style(self, generator):
        """Test that DALL-E 2 ignores quality and style parameters"""
        with patch('requests.post') as mock_post:
            mock_response = Mock()
            mock_response.status_code = 200
            mock_response.json.return_value = {"data": [{"url": "test"}]}
            mock_post.return_value = mock_response

            # Should not raise even though we pass quality/style
            generator.generate_image(
                prompt="Test",
                model=ImageGenerator.DALLE_2,
                quality="hd",  # Will be ignored
                style="natural"  # Will be ignored
            )

            payload = mock_post.call_args[1]["json"]
            # These should not be in the payload for DALL-E 2
            assert "quality" not in payload
            assert "style" not in payload


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
