"""Conservative inference of dependencies among sibling binary XCFrameworks."""

def _modules_in_all_interfaces(target):
    common = None
    evidence = {}
    for slice_info in target.slices:
        for interface in slice_info.interfaces:
            modules = {}
            for imp in interface.imports:
                if imp.module_name not in evidence:
                    evidence[imp.module_name] = "{}:{}".format(interface.path, imp.line_number)
                if not imp.is_conditional:
                    modules[imp.module_name] = True
            common = modules if common == None else {name: True for name in common if name in modules}
    return common or {}, evidence

def _has_coverage(importer, provider):
    for importer_slice in importer.slices:
        for interface in importer_slice.interfaces:
            found = False
            for provider_slice in provider.slices:
                for provider_interface in provider_slice.interfaces:
                    if provider_interface.basename == interface.basename:
                        found = True
                        break
            if not found:
                return False
    return True

def _find_cycle(edges, start, current):
    paths = [[current]]
    visited = {}
    for idx in range(len(edges) * len(edges) + 1):
        if idx >= len(paths):
            break
        path = paths[idx]
        name = path[-1]
        if name == start:
            return [start] + path
        if name in visited:
            continue
        visited[name] = True
        for next_name in sorted(edges.get(name, [])):
            paths.append(path + [next_name])
    return None

def _infer(targets, manual_edges = {}):
    """Returns inferred sibling names and diagnostics from injected metadata.

    Targets have name, module_name, complete, and slices with name and public
    interfaces. Each interface has path and imports from swift_files.collect_imports.
    """
    owners = {}
    for target in targets:
        if target.module_name:
            owners[target.module_name] = owners.get(target.module_name, []) + [target]
    inferred = {target.name: [] for target in targets}
    diagnostics = []
    evidence_by_edge = {}
    for importer in targets:
        if not importer.complete:
            diagnostics.append("{} has missing, ambiguous, or unsupported public Swift interfaces; configure target_deps manually".format(importer.name))
            continue
        common, evidence = _modules_in_all_interfaces(importer)
        for module_name in sorted(owners):
            if module_name == importer.module_name:
                continue
            candidates = owners[module_name]
            if len(candidates) != 1:
                if module_name in evidence:
                    diagnostics.append("{} imports ambiguous sibling module {} at {}; configure target_deps manually".format(importer.name, module_name, evidence[module_name]))
                continue
            provider = candidates[0]
            if provider.name == importer.name or module_name not in evidence:
                continue
            if not provider.complete:
                diagnostics.append("{} imports sibling module {} at {} but its public interfaces are incomplete; configure target_deps manually".format(importer.name, module_name, evidence[module_name]))
                continue
            if module_name not in common:
                diagnostics.append("{} imports sibling module {} at {} only conditionally or in some interfaces; configure target_deps manually".format(importer.name, module_name, evidence[module_name]))
                continue
            if not _has_coverage(importer, provider):
                diagnostics.append("{} imports sibling module {} at {} but XCFramework slice coverage differs; configure target_deps manually".format(importer.name, module_name, evidence[module_name]))
                continue
            inferred[importer.name].append(provider.name)
            evidence_by_edge[(importer.name, provider.name)] = evidence[module_name]
    edges = {name: list(manual_edges.get(name, [])) + inferred[name] for name in inferred}
    for name in sorted(edges):
        for dep_name in sorted(inferred[name]):
            cycle = _find_cycle(edges, name, dep_name)
            if cycle != None:
                locations = [evidence_by_edge.get((cycle[idx], cycle[idx + 1]), "manual dependency") for idx in range(len(cycle) - 1)]
                fail("Inferred binary target dependency cycle: {} ({}).".format(" -> ".join(cycle), ", ".join(locations)))
    return struct(deps = inferred, diagnostics = diagnostics)

binary_target_deps = struct(infer = _infer)
