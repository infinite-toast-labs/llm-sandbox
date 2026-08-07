"""Install the geolocation router into the packaged sandbox API at import time."""

from __future__ import annotations

import importlib.abc
import importlib.machinery
import sys
from types import ModuleType
from typing import Any


TARGET_MODULE = "app.api.router"


class RouterPatchLoader(importlib.abc.Loader):
    def __init__(self, wrapped: importlib.abc.Loader) -> None:
        self.wrapped = wrapped

    def create_module(self, spec: Any) -> ModuleType | None:
        create_module = getattr(self.wrapped, "create_module", None)
        return create_module(spec) if create_module else None

    def exec_module(self, module: ModuleType) -> None:
        self.wrapped.exec_module(module)
        original_register_routes = module.register_routes

        def register_routes(app: Any) -> None:
            original_register_routes(app)
            from sandbox_geolocation_api import router

            app.include_router(router, prefix="/v1/geolocation")

        module.register_routes = register_routes


class RouterPatchFinder(importlib.abc.MetaPathFinder):
    def find_spec(
        self,
        fullname: str,
        path: list[str] | None,
        target: ModuleType | None = None,
    ) -> Any:
        if fullname != TARGET_MODULE:
            return None
        spec = importlib.machinery.PathFinder.find_spec(fullname, path)
        if spec is None or spec.loader is None:
            return None
        spec.loader = RouterPatchLoader(spec.loader)
        return spec


sys.meta_path.insert(0, RouterPatchFinder())
