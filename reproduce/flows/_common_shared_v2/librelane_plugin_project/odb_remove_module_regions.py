# OpenDB script (run by the Project.RemoveModuleRegions step): delete the module regions (fences) created by odb_module_regions.py.
#
# OpenROAD treats a fence as exclusive: cells that belong to no group (clock-tree buffers, hold and timing-repair buffers inserted later)
# cannot be legalised inside it. The fences do their job in global and detailed placement; this step removes them afterwards so that
# CTS and the timing repair can place their cells anywhere. The module cells stay where detailed placement put them.
from reader import click, click_odb


@click.command()
@click_odb
def remove(reader):
    import odb

    block = reader.block
    regions = list(block.getRegions())
    groups = list(block.getGroups())
    for g in groups:
        odb.dbGroup_destroy(g)
    for r in regions:
        odb.dbRegion_destroy(r)
    print(f"[regions] removed {len(regions)} regions and {len(groups)} groups")


if __name__ == "__main__":
    remove()
