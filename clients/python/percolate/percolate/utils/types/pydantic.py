import typing
import pydantic
import pyarrow as pa
from datetime import date, datetime
import sys
import inspect
import types

def get_innermost_args(type_hint):
    """
    Recursively extracts the innermost type arguments from nested Optionals, Lists, and Unions.
    """

    if typing.get_origin(type_hint) is typing.Union:
        for arg in typing.get_args(type_hint):
            if arg is not type(None):  
                return get_innermost_args(arg)

    if typing.get_origin(type_hint) is list or type_hint == typing.List:
        list_args = typing.get_args(type_hint)
        if list_args:
            return get_innermost_args(list_args[0])

    return type_hint

def match_type(inner_type, base_type) -> bool:
    """
    Recursively check if any of the inner types match the base type.

    """
    arg = get_innermost_args(inner_type)
    if issubclass(arg, base_type):
        return arg

def get_model_reference_types(obj, model_root, visits=None):
    """given a model root (presume AbstractModel) find all types that references other types"""
    annotations = typing.get_type_hints(obj) 
    
    """bootstrapped from the root we know about"""
    if visits is None:
        visits = []
    else:
        visits.append(obj)
    for _, field_type in annotations.items():
        
        otype = match_type(field_type, model_root)
        if otype and otype not in visits:
            get_model_reference_types(otype, model_root, visits)
    return visits



    
    
def get_pydantic_properties_string(cls, child_types=None):
    """
    this is useful as a prompting device
    """
    annotations = typing.get_type_hints(cls)
    
    """if known child types are provided, we render them first"""
    child_strings = f"\n\n".join(get_pydantic_properties_string(t) for t in child_types or [])
    
    class_str = f"\n\nclass {cls.__name__}(BaseModel)\n"
    for field_name, field_type in annotations.items():
        field_default = getattr(cls, field_name, ...)
        field_info = cls.__fields__.get(field_name)
        description = (
            f" # {field_info.description}"
            if getattr(field_info, "description", None)
            else ""
        )
        type_str = repr(field_type)

        if field_default is ...:
            class_str += f"  -  {field_name}: {type_str}{description}\n"
        else:
            if isinstance(field_default, pydantic.Field):

                class_str += f" - {field_name}: {type_str} = Field(default={repr(field_default.default)}) {description}\n"
            else:
                class_str += f" - {field_name}: {type_str} = {repr(field_default)} {description}\n"
    return child_strings + class_str


def get_extras(field_info, key: str):
    """
    Get the extra metadata from a Pydantic FieldInfo.
    """
    return (field_info.json_schema_extra or {}).get(key)


def _py_type_to_arrow_type(py_type, field, coerce_str=True):
    """Convert a field with native Python type to Arrow data type.

    Raises
    ------
    TypeError
        If the type is not supported.
    """
    
    origin = typing.get_origin(py_type)
    args = typing.get_args(py_type)

    # Handle Optional types (e.g., Optional[int])
    if origin is typing.Union and type(None) in args:
        non_none_args = [arg for arg in args if arg is not type(None)]
        if len(non_none_args) == 1:
            return _py_type_to_arrow_type(non_none_args[0], field, coerce_str)
        else:
            raise TypeError(f"Unsupported Union type with multiple non-None arguments: {py_type}")

    # List types with type arguments
    if origin in (list, typing.List):
        if not args:
            return pa.list_(pa.utf8())  # Default to list of strings if no type args
        item_type = args[0]
        return pa.list_(_py_type_to_arrow_type(item_type, field, coerce_str))

    # Dict types with type arguments
    if origin in (dict, typing.Dict):
        if len(args) != 2:
            return pa.map_(pa.utf8(), pa.utf8())  # Default to string keys/values if wrong args
        key_type, value_type = args
        key_arrow_type = _py_type_to_arrow_type(key_type, field, coerce_str)
        value_arrow_type = _py_type_to_arrow_type(value_type, field, coerce_str)
        return pa.map_(key_arrow_type, value_arrow_type)
    
    
    # Basic types
    if py_type == int:
        return pa.int64()
    elif py_type == float:
        return pa.float64()
    elif py_type == str:
        return pa.utf8()
    elif py_type == bool:
        return pa.bool_()
    elif py_type == bytes:
        return pa.binary()
    elif py_type == date:
        return pa.date32()
    elif py_type == datetime:
        tz = get_extras(field, "tz")
        return pa.timestamp("us", tz=tz)
    elif py_type == dict:
        # For raw dict type without type arguments, use string keys and values
        return pa.utf8()#pa.json_( )
    elif py_type == list:
        # For raw list type without type arguments, use string values
        return pa.list_(pa.utf8())


    # Handle pydantic BaseModel types as struct fields
    if inspect.isclass(py_type) and hasattr(py_type, 'model_fields'):
        # For pydantic models that aren't handled earlier, convert to struct
        fields = []
        for name, field_info in py_type.model_fields.items():
            field_type = field_info.annotation
            try:
                arrow_type = _py_type_to_arrow_type(field_type, field_info, coerce_str)
                fields.append(pa.field(name, arrow_type, True))  # Allow nulls for nested fields
            except Exception:
                # If a field type conversion fails, default to string
                fields.append(pa.field(name, pa.utf8(), True))
        return pa.struct(fields)
    
    # Default to string for unrecognized types if coercion is enabled
    if coerce_str:
        return pa.utf8()

    raise TypeError(
        f"Converting Pydantic type to Arrow Type: unsupported type {py_type}."
    )


def is_nullable(field) -> bool:
    """Check if a Pydantic FieldInfo is nullable."""
    if isinstance(field.annotation, typing._GenericAlias):
        origin = field.annotation.__origin__
        args = field.annotation.__args__
        if origin == typing.Union:
            if len(args) == 2 and args[1] == type(None):
                return True
    elif sys.version_info >= (3, 10) and isinstance(field.annotation, types.UnionType):
        args = field.annotation.__args__
        for typ in args:
            if typ == type(None):
                return True
    return False


def _pydantic_model_to_fields(model: pydantic.BaseModel) -> typing.List[pa.Field]:
    return [_pydantic_to_field(name, field) for name, field in model.__fields__.items()]


def _pydantic_to_arrow_type(field) -> pa.DataType:
    """Convert a Pydantic FieldInfo to Arrow DataType"""

    if isinstance(field.annotation, typing._GenericAlias) or (
        sys.version_info > (3, 9) and isinstance(field.annotation, types.GenericAlias)
    ):
        origin = field.annotation.__origin__
        args = field.annotation.__args__
        if origin == list:
            child = args[0]
            return pa.list_(_py_type_to_arrow_type(child, field))
        elif origin == typing.Union:
            if len(args) == 2 and args[1] == type(None):
                return _py_type_to_arrow_type(args[0], field)
    elif sys.version_info >= (3, 10) and isinstance(field.annotation, types.UnionType):
        args = field.annotation.__args__
        if len(args) == 2:
            for typ in args:
                if typ == type(None):
                    continue
                return _py_type_to_arrow_type(typ, field)
    elif inspect.isclass(field.annotation):
        if issubclass(field.annotation, pydantic.BaseModel):
            # Struct
            fields = _pydantic_model_to_fields(field.annotation)
            return pa.struct(fields)
    #         elif issubclass(field.annotation, FixedSizeListMixin):
    #             return pa.list_(field.annotation.value_arrow_type(), field.annotation.dim())
    return _py_type_to_arrow_type(field.annotation, field)


def _pydantic_to_field(name: str, field) -> pa.Field:
    """Convert a Pydantic field to a PyArrow Field."""
    dt = _pydantic_to_arrow_type(field)
    return pa.field(name, dt, is_nullable(field))


def pydantic_to_arrow_schema(
    model: pydantic.BaseModel, metadata: dict = None
) -> typing.List[pa.Field]:
    """
    convert a pydantic schema to arrow schema in some sort of opinionated way e.g. dealing with complex types
    """
    fields = [
        _pydantic_to_field(name, field) for name, field in model.model_fields.items()
    ]

    schema = pa.schema(fields)

    if metadata:
        schema = schema.with_metadata(metadata)

    return schema


def arrow_type_to_iceberg_type(pa_type):
    """
    Convert a PyArrow data type to a PyIceberg data type.
    This is used for schema evolution when adding new fields.
    
    Args:
        pa_type: PyArrow data type
        
    Returns:
        PyIceberg data type
    """
    try:
        from pyiceberg.types import (
            StringType, LongType, DoubleType, BooleanType, 
            TimestampType, ListType, MapType, StructType
        )
    except ImportError:
        # If PyIceberg is not available, return None
        return None
        
    # Map PyArrow types to PyIceberg types
    # This is more precise than string matching
    arrow_to_iceberg_map = {
        pa.string(): StringType(),
        pa.utf8(): StringType(),
        pa.large_string(): StringType(),
        pa.int8(): LongType(),
        pa.int16(): LongType(),
        pa.int32(): LongType(),
        pa.int64(): LongType(),
        pa.float32(): DoubleType(),
        pa.float64(): DoubleType(),
        pa.bool_(): BooleanType(),
        pa.date32(): TimestampType(),
        pa.timestamp('us'): TimestampType(),
       
    }
    
    # Try direct type mapping first
    if pa_type in arrow_to_iceberg_map:
        return arrow_to_iceberg_map[pa_type]
        
    # Handle complex types
    type_str = str(pa_type).lower()
    
    # Handle list types
    if isinstance(pa_type, pa.ListType):
        try:
            # PyIceberg 0.9.0 has a different API for complex types
            # Check the available parameters
            import inspect
            list_sig = inspect.signature(ListType.__init__)
            
            if 'element_type' in list_sig.parameters:
                # Newer versions of PyIceberg
                element_type = arrow_type_to_iceberg_type(pa_type.value_type)
                return ListType(element_type=element_type, element_required=False)
            else:
                # PyIceberg 0.9.0
                element_type = arrow_type_to_iceberg_type(pa_type.value_type)
                return ListType(element=element_type, element_required=False)
        except Exception as ex:
            # Default to string lists if conversion fails
            # Different approach based on PyIceberg version
            try:
                return ListType(element=StringType(), element_required=False)
            except:
                return StringType()  # Fallback to simple string type
            
    # Handle map types
    elif isinstance(pa_type, pa.MapType):
        try:
            # PyIceberg 0.9.0 has a different API for complex types
            # Check the available parameters
            import inspect
            map_sig = inspect.signature(MapType.__init__)
            
            key_type = arrow_type_to_iceberg_type(pa_type.key_type)
            value_type = arrow_type_to_iceberg_type(pa_type.item_type)
            
            if 'key_type' in map_sig.parameters and 'value_type' in map_sig.parameters:
                # Newer versions of PyIceberg
                return MapType(key_type=key_type, value_type=value_type, value_required=False)
            else:
                # PyIceberg 0.9.0
                return MapType(key=key_type, value=value_type, value_required=False)
        except:
            # Default to string->string map if conversion fails
            try:
                return MapType(key=StringType(), value=StringType(), value_required=False)
            except:
                return StringType()  # Fallback to simple string type
            
    # Handle struct types
    elif isinstance(pa_type, pa.StructType):
        # Convert each field in the struct
        try:
            fields = []
            for i in range(pa_type.num_fields):
                field = pa_type.field(i)
                field_type = arrow_type_to_iceberg_type(field.type)
                fields.append((field.name, field_type))
                
            # PyIceberg 0.9.0 has a different API for complex types
            # Check if this version of PyIceberg accepts fields directly
            try:
                return StructType(fields=fields)
            except:
                # In PyIceberg 0.9.0, passing fields directly might work
                return StructType(fields)
        except:
            # Default to string type if struct creation fails
            return StringType()
    
    # Fallback to string matching for other types
    if "int" in type_str or "long" in type_str:
        return LongType()
    elif "float" in type_str or "double" in type_str:
        return DoubleType()
    elif "bool" in type_str:
        return BooleanType()
    elif "timestamp" in type_str or "date" in type_str:
        return TimestampType()
        
    # Default to string for unknown types
    return StringType()


def get_type(type_str: str) -> typing.Any:
    """typing helper"""

    type_mappings = {
        "str": str,
        "Optional[str]": typing.Optional[str],
        "List[str]": typing.List[str],
        "Optional[List[str]]": typing.Optional[typing.List[str]],
        "bool": bool,
        "int": float,
        "int": int,
    }
    """attempts to eval if not mapping"""
    return type_mappings.get(type_str) or  eval(type_str)

 
class JsonSchemaConverter:
    """Converts JSON Schema to Pydantic fields"""
    
    @staticmethod
    def json_type_to_python_type(json_type: str, format: str = None, items: dict = None) -> typing.Any:
        """Convert JSON Schema type to Python type annotation"""
        if json_type == "string":
            if format == "date":
                return date
            elif format == "date-time":
                return datetime
            elif format == "uuid":
                return str  # Could use UUID type but str is more flexible
            return str
        elif json_type == "number":
            return float
        elif json_type == "integer":
            return int
        elif json_type == "boolean":
            return bool
        elif json_type == "array":
            if items:
                item_type = JsonSchemaConverter.json_type_to_python_type(
                    items.get("type", "string"),
                    items.get("format"),
                    items.get("items")
                )
                return typing.List[item_type]
            return typing.List[typing.Any]
        elif json_type == "object":
            # For nested objects, we could create a nested model
            # For now, return dict
            return dict
        elif json_type == "null":
            return type(None)
        else:
            return typing.Any
    
    @staticmethod
    def fields_from_json_schema(
        json_schema: dict, 
        parent_model: pydantic.BaseModel = None
    ) -> typing.Dict[str, typing.Tuple[typing.Any, pydantic.Field]]:
        """
        Convert a standard JSON Schema to Pydantic field definitions
        
        Args:
            json_schema: Standard JSON Schema dict with type, properties, etc.
            parent_model: Optional parent model to inherit field extras from
            
        Returns:
            Dict mapping field names to (type, Field) tuples for create_model
        """
        fields = {}
        
        # Handle the standard JSON Schema structure
        if json_schema.get("type") == "object" and "properties" in json_schema:
            properties = json_schema["properties"]
            required_fields = set(json_schema.get("required", []))
            
            # Get parent field extras if available
            field_extra_info = {}
            if parent_model:
                # Access model_fields from the class, not instance
                model_class = parent_model if inspect.isclass(parent_model) else parent_model.__class__
                for k, v in model_class.model_fields.items():
                    if hasattr(v, 'json_schema_extra'):
                        field_extra_info[k] = v.json_schema_extra
            
            for field_name, field_schema in properties.items():
                # Handle anyOf/oneOf unions
                if "anyOf" in field_schema:
                    types = []
                    for option in field_schema["anyOf"]:
                        if option.get("type") == "null":
                            continue  # Handle null separately
                        opt_type = JsonSchemaConverter.json_type_to_python_type(
                            option.get("type", "string"),
                            option.get("format"),
                            option.get("items")
                        )
                        types.append(opt_type)
                    
                    # Check if null is one of the options
                    has_null = any(opt.get("type") == "null" for opt in field_schema["anyOf"])
                    
                    if len(types) == 1:
                        field_type = types[0]
                        if has_null or field_name not in required_fields:
                            field_type = typing.Optional[field_type]
                    elif len(types) > 1:
                        # Create a Union type
                        field_type = typing.Union[tuple(types)]
                        if has_null:
                            field_type = typing.Optional[field_type]
                    else:
                        # All options were null
                        field_type = type(None)
                else:
                    # Regular type handling
                    field_type = JsonSchemaConverter.json_type_to_python_type(
                        field_schema.get("type", "string"),
                        field_schema.get("format"),
                        field_schema.get("items")
                    )
                    
                    # Handle nullable/optional types
                    if field_name not in required_fields:
                        field_type = typing.Optional[field_type]
                
                # Extract field metadata
                description = field_schema.get("description", "")
                default = field_schema.get("default", ... if field_name in required_fields else None)
                
                # Handle additional constraints
                field_kwargs = {"description": description}
                
                # Add constraints from JSON Schema
                if "minimum" in field_schema:
                    field_kwargs["ge"] = field_schema["minimum"]
                if "maximum" in field_schema:
                    field_kwargs["le"] = field_schema["maximum"]
                if "minLength" in field_schema:
                    field_kwargs["min_length"] = field_schema["minLength"]
                if "maxLength" in field_schema:
                    field_kwargs["max_length"] = field_schema["maxLength"]
                if "pattern" in field_schema:
                    field_kwargs["pattern"] = field_schema["pattern"]
                if "enum" in field_schema:
                    # For enums, we could create a proper Enum type
                    # For now, use Literal
                    from typing import Literal
                    field_type = Literal[tuple(field_schema["enum"])]
                
                # Include parent extras if available
                extra_fields = field_extra_info.get(field_name, {})
                field_kwargs.update(extra_fields)
                
                # Create the field
                fields[field_name] = (field_type, pydantic.Field(default, **field_kwargs))
        
        # Also support the simplified format (backward compatibility)
        elif all(isinstance(v, dict) and "type" in v for v in json_schema.values()):
            return get_field_annotations_from_json(json_schema, parent_model)
        
        return fields


def get_field_annotations_from_json(json_schema:dict, parent_model:pydantic.BaseModel=None) -> typing.Dict[str, typing.Any]:
    """provide name mapped to type and description attributes
      types are assumed to be the python type annotations in string format for now. defaults can also be added and we should play with enums
      
      if a parent model is supplied we will inherit json schema extra from those properties (or you can omit the property)
      an example is detail about content embedding
    """
    try:
        field_extra_info = {}
        if parent_model:
            # Access model_fields from the class, not instance
            model_class = parent_model if inspect.isclass(parent_model) else parent_model.__class__
            for k,v in model_class.model_fields.items():
                if hasattr(v, 'json_schema_extra'):
                    field_extra_info[k] = v.json_schema_extra
            
        fields: typing.Dict[str, typing.Any] = {}

        for field_name, field_info in json_schema.items():
            field_type = get_type(field_info["type"])
            description = field_info.get("description", "")
            default_value = field_info.get("default", None) # ..., default factory and other options here
            """from the parent model we may have extra attributes to include but it may not always be what we want. experimental"""
            extra_fields = field_extra_info.get(field_name) or {}
            fields[field_name] = (field_type, pydantic.Field(default_value, description=description, **extra_fields))

        return fields
    except Exception as ex:
        raise ValueError(f"Failing to map type annotations {json_schema=} due to {ex=}")