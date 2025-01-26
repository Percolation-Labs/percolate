from .CallingContext import CallingContext

class LanguageModel:
    @classmethod 
    def from_context(cls, context: CallingContext) -> "LanguageModel":
        pass