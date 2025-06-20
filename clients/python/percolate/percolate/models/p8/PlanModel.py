from pydantic import Field, model_validator
import typing
from ..AbstractModel import AbstractModel 
import uuid

def create_lookup(
    data: typing.Dict[str, typing.Any]
) -> typing.Dict[str, typing.Dict[str, typing.Any]]:
    """in a DAG where we are being efficient with named refs, we can get a lookup of all nodes with this and then expand for pydantic"""
    lookup = {}

    def _traverse(node: typing.Dict[str, typing.Any]):
        if "plan_description" in node:
            if node["name"] not in lookup:
                lookup[node["name"]] = {}
            lookup[node["name"]].update(node)
        if "depends" in node:
            for dep in node["depends"]:
                _traverse(dep)

    _traverse(data)
    return lookup


def expand_refs(
    node: typing.Dict[str, typing.Any],
    lookup: typing.Dict[str, typing.Dict[str, typing.Any]],
) -> typing.Dict[str, typing.Any]:
    """in a DAG where we are being efficient with named refs, we can get a lookup of all nodes with this and then expand for pydantic using this function"""
    if "depends" in node:
        expanded_depends = []
        for dep in node["depends"]:
            dep_name = dep["name"]
            if dep_name in lookup:
                expanded_dep = expand_refs(lookup[dep_name], lookup)
                expanded_depends.append(expanded_dep)
            else:
                expanded_depends.append(dep)
        node["depends"] = expanded_depends
    return node


class PlanFunctions(AbstractModel):
    name: str = Field(
        description="fully qualified function name e.g. <namespace>_<name>"
    )
    description: str = Field(
        description="a description of the function preferably with the current context taken into account e.g. provide good example parameters"
    )
    rating: float = Field(
        description="a rating from 0 to 100 for how useful this function should be in context"
    )

class ConcisePlanner(AbstractModel):
    """You are given access to a user question and a range of functions.
    Choose a small set of functions that are required or useful to answer the users question.
    Respond in a json format with the fully qualified function name, ranking (with respect to question) and short comment 
    You should bot provide preamble or discussion and be as brief as possible.
    The user can activate the functions by name to learn more.
    """
    pass

class PlanModel(AbstractModel):
    """
    You are an agent that plans function calling and agent resources for other agents but you do not call functions yourself.
    Respond to the caller only with the context you ascertain from the data you are given.
    You should construct a Directed Acyclic Graph (RAG) of one or more functions that can be called.
    Observe where there are dependencies between functions
    """

    id : typing.Optional[uuid.UUID | str ] = Field(None, description="An id for the plan - better to set this but we can add them uniquely to users and sessions to")
    name: typing.Optional[str] = Field(
        description="The unique name of the plan node", default=None
    )

    plan_description: str = Field(
        description="The plan to prompt the agent - should provide fully strategy and explain what dependencies exist with other stages"
    )
    questions: typing.Optional[typing.List[str]] = Field(
        description="The question in this plan instance as the user would ask it. A plan can be constructed without a clear question",
        default=None,
    )
    extra_arguments: typing.Optional[dict] = Field(
        description="Placeholder/hint for extra parameters that should be passed from previous stages such as data or identifiers that were discovered in the data and expected by the function either as a parameter or important context",
        default=None,
    )
    functions: typing.Optional[typing.List[PlanFunctions]] = Field(
        description="A collection of functions designed for use with this context",
        default=None,
    )
    depends: typing.Optional[typing.List["PlanModel"]] = Field(
        description="A dependency graph - plans can be chained into waves of functions that can be called in parallel or one after the other. Data dependencies are injected to downstream plans",
        default=None,
    )
    userid: typing.Optional[str] = Field(None, description="A user that owns the plan")

    @model_validator(mode="before")
    @classmethod
    def _expand(cls, values):
        """expand entity refs for pydantic model"""
        l = create_lookup(values)
        values = expand_refs(values, l)
        return values

    # @property
    # def plan_dependency_image(cls) -> Image.Image:
    #     """A PNG format of the plan"""
    #     return Image.open(BytesIO(cls.draw_plan_dependency_graph()._repr_image_png()))

    def draw_plan_dependency_graph(cls):
        """simple plan viz"""
        from graphviz import Digraph

        dot = Digraph(comment="Plan Dependency Graph")

        def add_node(node, parent=None):
            node_label = f'{node["name"]}\n{node["plan_description"]}'
            dot.node(node["name"], label=node_label, shape="box")

            if parent:
                dot.edge(node["name"], parent, dir="back")

            for func in node["functions"]:
                func_label = f'{func["name"]}({", ".join(func.get("arguments", []))})'
                dot.node(func_label, shape="ellipse")
                dot.edge(node["name"], func_label)

            if node["depends"]:
                for dependency in node["depends"]:
                    add_node(dependency, node["name"])

        add_node(cls.model_dump())

        return dot
