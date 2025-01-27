import typing,types
import inspect
import importlib
import pkgutil
from pydantic import BaseModel

def object_namespace(o, default:str='public', exclude:typing.List[str]|str=None):
    """
    simple wrapper to get object namespace as a module but do not allow some and use public as default
    """
    
    exclude = exclude or ["__main__"]
    if not isinstance(exclude,list):
        exclude = [exclude]
    """this convention assumes that types are in a file and the container module is the namespace"""
    parts = o.__module__.split(".")
    """convention"""
    namespace = parts[-2] if len(parts) > 1 else parts[-1]
    if namespace not in exclude:
        return namespace
    return default

def get_object_id(o)->str:
    """
    assume this is some object type or instance
    """
    
    if hasattr(o, 'get_model_full_name'):
        return o.get_model_full_name()
    if hasattr(o,'__name__'):
        return f"{object_namespace(o)}.{o.__name__}"
    
    return str(o) 

def get_classes(
    base_filter: type = None,
    package: typing.Union[str, types.ModuleType] = "percolate.models.p8",
    exclusions: typing.List[str] = None,
) -> list[type]:
    """Recurse and get classes implementing a base class.

    Args:
        base_filter (type, optional): The base class or type to filter results.
        package (Union[str, types.ModuleType], optional): Package name as a string
            or an already-imported module. 
        exclusions (List[str], optional): List of module names to exclude. Defaults to None.

    Returns:
        List[type]: List of classes that match the base_filter.
    """
    exclusions = exclusions or []
    classes_in_package = []

    # If `package` is a string, import it as a module; otherwise, use it directly
    if isinstance(package, str):
        package = importlib.import_module(package)

    # Verify the package has a __path__ attribute (only works for packages, not single modules)
    if not hasattr(package, "__path__"):
        raise ValueError(f"{package} is not a package. Only packages are supported.")

    # Go through the modules in the package
    for _importer, module_name, is_package in pkgutil.iter_modules(package.__path__):
        full_module_name = f"{package.__name__}.{module_name}"
        if full_module_name in exclusions:
            continue

        # Import the module
        module = importlib.import_module(full_module_name)

        # Inspect and collect classes in the module
        for name, obj in inspect.getmembers(module, inspect.isclass):
            if (
                obj.__module__ == full_module_name
            ):  # Ensure the class belongs to this module
                if not base_filter or issubclass(obj, base_filter):
                    classes_in_package.append(obj)

        # Recurse into sub-packages
        if is_package:
            classes_in_subpackage = get_classes(
                base_filter=base_filter, package=module, exclusions=exclusions
            )
            classes_in_package.extend(classes_in_subpackage)

        # Load the module for inspection
        module = importlib.import_module(full_module_name)

        # Iterate through all the objects in the module and
        # using the lambda, filter for class objects and only objects that exist within the module
        for _name, obj in inspect.getmembers(
            module,
            lambda member, module_name=full_module_name: inspect.isclass(member)
            and member.__module__ == module_name,
        ):
            classes_in_package.append(obj)
    visited = (
        classes_in_package
        if not base_filter
        else [c for c in classes_in_package if issubclass(c, base_filter)]
    )

    return set(visited)


def load_model(name:str, case_sensitive: bool = True):
    """
    loads the model by name
    """
    from percolate.models.AbstractModel import AbstractModel

    models: typing.List[AbstractModel] = get_classes(AbstractModel)
    models = (
        [m for m in models if m.get_model_full_name() == name]
        if case_sensitive
        else [
            m for m in models if str(m.get_model_full_name()).lower() == name.lower()
        ]
    )
    if not models:
        raise Exception(f"Could not load {name} from models")
    return models[0]



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


def get_ref_types(cls:BaseModel, model_root: BaseModel=None):
    """get all the Abstract/Base Models referenced in the type including self"""
    from percolate.models import AbstractModel
    
    types = []
    model_root = model_root or AbstractModel

    def _get_ref_types(cls, types: typing.List[typing.Type]):
        types.append(cls)
        for _, v in cls.model_fields.items():
            t = get_innermost_args(v.annotation)
            if match_type(t, model_root) and v not in types:
                _get_ref_types(t, types)
        return types

    return _get_ref_types(cls, types)

def is_strict_subclass(subclass, superclass):
    try:
        if not subclass:
            return False
        return issubclass(subclass, superclass) and subclass is not superclass
    except:
        raise ValueError(
            f"failed to check {subclass}, {superclass} as a strict subclass relationship"
        )

def get_defining_class(member, cls):
    defining_class = getattr(member, "__objclass__", None)
    if defining_class:
        return defining_class

    for base_class in cls.mro():
        if member.__name__ in base_class.__dict__:
            return base_class
    return None

def get_class_and_instance_methods(cls, inheriting_from: type = None):
    """inspect the methods on the type for methods

    by default only the classes methods are used or we can take anything inheriting from a base such as AbstractModel (not in)

    Args:
        inheriting_from: create the excluded base from which to inherit.
        In our case we want to treat the AbstractModel as a base that does not share properties
    """
    methods = []
    class_methods = []

    def __inherits(member):
        """
        find out of a member inherits from something we care about, not including the thing itself
        """
        if not inheriting_from:
            return True

        """we can traverse up to a point"""
        return is_strict_subclass(get_defining_class(member, cls), inheriting_from)

    for name, member in inspect.getmembers(cls):
        if inspect.isfunction(member) or inspect.ismethod(member):
            # Check if the method belongs to the class and not inherited
            if member.__qualname__.startswith(cls.__name__) or __inherits(member):
                if isinstance(member, types.FunctionType):
                    methods.append(getattr(cls, name))
                elif isinstance(member, types.MethodType):
                    class_methods.append(getattr(cls, name))

    return methods + class_methods
