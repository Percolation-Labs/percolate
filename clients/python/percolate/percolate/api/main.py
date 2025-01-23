from fastapi import FastAPI, Query
from pydantic import BaseModel, Field
from typing import Optional

app = FastAPI(
    title="Weather Service API",
    description=(
        "A simple weather service API that provides weather information for a given city. "
        "It allows you to fetch current temperature, humidity, and weather conditions."
    ),
    version="1.0.0",
    contact={
        "name": "Weather API Support",
        "url": "https://weatherapi.example.com/contact",
        "email": "support@weatherapi.example.com",
    },
    license_info={
        "name": "MIT",
        "url": "https://opensource.org/licenses/MIT",
    },
)

# Pydantic model for the weather response
class WeatherResponse(BaseModel):
    city: str = Field(..., description="The name of the city for which weather data is provided.")
    temperature: float = Field(..., description="The current temperature in Celsius.")
    humidity: int = Field(..., description="The current humidity percentage.")
    condition: str = Field(..., description="A brief description of the weather condition (e.g., Clear, Rainy).")

@app.get(
    "/weather",
    response_model=WeatherResponse,
    summary="Get Weather Information",
    description=(
        "Fetch the current weather information for a specific city. "
        "The response includes the temperature, humidity, and weather condition."
    ),
    tags=["Weather"],
)
async def get_weather(
    city: str = Query(
        ...,
        description="The name of the city for which to fetch weather information.",
        examples=["Paris"],
    ),
    units: Optional[str] = Query(
        "metric",
        description=(
            "The unit system for temperature. Options are:\n\n"
            "- `metric`: Celsius\n"
            "- `imperial`: Fahrenheit\n"
        )
    ),
) -> WeatherResponse:
    """
    Fetch the current weather for a given city.

    - **city**: The name of the city to retrieve weather for.
    - **units**: The unit system for temperature, either `metric` (Celsius) or `imperial` (Fahrenheit).
    
    Returns:
        A JSON object containing the weather data:
        - **city**: The name of the city.
        - **temperature**: The current temperature in the requested unit.
        - **humidity**: The percentage of humidity.
        - **condition**: A brief description of the weather condition.
    """

    # Mock weather data (Replace this with an actual API call to a weather provider)
    mock_data = {
        "Paris": {"temperature": 20.5, "humidity": 65, "condition": "Clear"},
        "New York": {"temperature": 25.3, "humidity": 70, "condition": "Rainy"},
        "Tokyo": {"temperature": 18.7, "humidity": 60, "condition": "Cloudy"},
    }

    weather = mock_data.get(city)

    if not weather:
        return WeatherResponse(
            city=city,
            temperature=0.0,
            humidity=0,
            condition="Unknown",
        )

    temperature = weather["temperature"]
    if units == "imperial":
        temperature = temperature * 9 / 5 + 32  # Convert to Fahrenheit

    return WeatherResponse(
        city=city,
        temperature=temperature,
        humidity=weather["humidity"],
        condition=weather["condition"],
    )
