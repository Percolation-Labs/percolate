"""
Unit tests for ModelRunner image generation integration.

Tests that the ModelRunner correctly integrates image generation
when allow_generate_image is set in model_config.
"""

import pytest
from unittest.mock import Mock, patch, MagicMock
from percolate.models import AbstractModel
from percolate.services.ModelRunner import ModelRunner


class TestModelRunnerImageGeneration:
    """Test ModelRunner's image generation integration"""

    @pytest.fixture
    def image_enabled_model(self):
        """Create a model with image generation enabled"""
        class ImageEnabledAgent(AbstractModel):
            """Test agent with image generation"""
            model_config = {"allow_generate_image": True}

        return ImageEnabledAgent

    @pytest.fixture
    def image_disabled_model(self):
        """Create a model without image generation"""
        class RegularAgent(AbstractModel):
            """Regular agent without image generation"""
            model_config = {}

        return RegularAgent

    def test_image_generation_enabled(self, image_enabled_model):
        """Test that image generation is enabled when allow_generate_image is True"""
        with patch('percolate.services.ModelRunner.p8.repository'):
            runner = ModelRunner(model=image_enabled_model)

            # Check that the method detects image generation is allowed
            assert runner._agent_allows_image_generation() is True

            # Check that generate_image function is registered
            assert 'generate_image' in runner._function_manager._functions

    def test_image_generation_disabled(self, image_disabled_model):
        """Test that image generation is not enabled by default"""
        with patch('percolate.services.ModelRunner.p8.repository'):
            runner = ModelRunner(model=image_disabled_model)

            # Check that image generation is not allowed
            assert runner._agent_allows_image_generation() is False

            # Check that generate_image function is NOT registered
            assert 'generate_image' not in runner._function_manager._functions

    @patch('percolate.services.llm.ImageGenerator.ImageGenerator')
    @patch('percolate.services.S3Service.S3Service')
    def test_generate_image_function_success(
        self,
        mock_s3_class,
        mock_generator_class,
        image_enabled_model
    ):
        """Test the generate_image function works correctly"""
        # Mock ImageGenerator
        mock_generator = Mock()
        mock_generator.generate_and_save_to_s3.return_value = {
            "generation": {
                "data": [{
                    "url": "https://example.com/image.png",
                    "revised_prompt": "A beautiful sunset"
                }]
            },
            "s3_upload": {
                "uri": "s3://bucket/images/test.png",
                "status": "success"
            },
            "model": "dall-e-3"
        }
        mock_generator_class.return_value = mock_generator

        # Mock S3Service
        mock_s3 = Mock()
        mock_s3.get_presigned_url_for_uri.return_value = "https://presigned-url.com/image.png"
        mock_s3_class.return_value = mock_s3

        with patch('percolate.services.ModelRunner.p8.repository'):
            runner = ModelRunner(model=image_enabled_model)

            # Call generate_image
            result = runner.generate_image(
                prompt="A sunset over mountains",
                size="1024x1024",
                quality="standard",
                style="vivid"
            )

            # Verify result structure
            assert result["status"] == "success"
            assert result["s3_uri"] == "s3://bucket/images/test.png"
            assert result["presigned_url"] == "https://presigned-url.com/image.png"
            assert "markdown" in result
            assert "![Generated Image]" in result["markdown"]
            assert result["image_info"]["prompt"] == "A sunset over mountains"

            # Verify ImageGenerator was called correctly
            mock_generator.generate_and_save_to_s3.assert_called_once()
            call_kwargs = mock_generator.generate_and_save_to_s3.call_args[1]
            assert call_kwargs["prompt"] == "A sunset over mountains"
            assert call_kwargs["size"] == "1024x1024"
            assert call_kwargs["quality"] == "standard"
            assert call_kwargs["style"] == "vivid"

            # Verify presigned URL was generated
            mock_s3.get_presigned_url_for_uri.assert_called_once_with(
                s3_uri="s3://bucket/images/test.png",
                expires_in=3600
            )

    @patch('percolate.services.llm.ImageGenerator.ImageGenerator')
    def test_generate_image_error_handling(self, mock_generator_class, image_enabled_model):
        """Test that errors in image generation are handled gracefully"""
        # Mock ImageGenerator to raise an error
        mock_generator = Mock()
        mock_generator.generate_and_save_to_s3.side_effect = Exception("API error")
        mock_generator_class.return_value = mock_generator

        with patch('percolate.services.ModelRunner.p8.repository'):
            runner = ModelRunner(model=image_enabled_model)

            # Call generate_image
            result = runner.generate_image(prompt="Test")

            # Verify error is returned gracefully
            assert result["status"] == "error"
            assert "API error" in result["error"]
            assert "Failed to generate image" in result["message"]

    @patch('percolate.services.llm.ImageGenerator.ImageGenerator')
    @patch('percolate.services.S3Service.S3Service')
    def test_generate_image_with_user_context(
        self,
        mock_s3_class,
        mock_generator_class,
        image_enabled_model
    ):
        """Test that user context affects S3 path"""
        # Mock services
        mock_generator = Mock()
        mock_generator.generate_and_save_to_s3.return_value = {
            "generation": {"data": [{"url": "test", "revised_prompt": "test"}]},
            "s3_upload": {"uri": "s3://bucket/user_123/images/test.png"},
            "model": "dall-e-3"
        }
        mock_generator_class.return_value = mock_generator

        mock_s3 = Mock()
        mock_s3.get_presigned_url_for_uri.return_value = "https://presigned.com/test.png"
        mock_s3_class.return_value = mock_s3

        with patch('percolate.services.ModelRunner.p8.repository'):
            # Create runner with user context
            runner = ModelRunner(
                model=image_enabled_model,
                user_id="user-123"
            )

            result = runner.generate_image(prompt="Test")

            # Verify project_name includes user_id
            call_kwargs = mock_generator.generate_and_save_to_s3.call_args[1]
            assert "user_123" in call_kwargs["project_name"] or "user-123" in call_kwargs["project_name"]

    def test_user_role_agent_has_image_generation(self):
        """Test that UserRoleAgent has image generation enabled"""
        from percolate.models.p8.types import UserRoleAgent

        # Check model config
        assert UserRoleAgent.model_config.get("allow_generate_image") is True

        with patch('percolate.services.ModelRunner.p8.repository'):
            runner = ModelRunner(model=UserRoleAgent)

            # Verify it's detected as enabled
            assert runner._agent_allows_image_generation() is True

            # Verify function is registered
            assert 'generate_image' in runner._function_manager._functions

    def test_web_search_and_image_generation_coexist(self):
        """Test that web search and image generation can both be enabled"""
        class MultiCapabilityAgent(AbstractModel):
            """Agent with multiple capabilities"""
            model_config = {
                "allow_search": True,
                "allow_generate_image": True
            }

        with patch('percolate.services.ModelRunner.p8.repository'):
            runner = ModelRunner(model=MultiCapabilityAgent)

            # Both should be enabled
            assert runner._agent_allows_web_search() is True
            assert runner._agent_allows_image_generation() is True

            # Both functions should be registered
            assert 'search_the_web' in runner._function_manager._functions
            assert 'generate_image' in runner._function_manager._functions


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
