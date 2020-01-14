// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:html';
import 'dart:math' as Math;
import 'dart:typed_data';
import 'package:observatory/models.dart' as M;
import 'package:observatory/heap_snapshot.dart' as S;
import 'package:observatory/object_graph.dart';
import 'package:observatory/src/elements/class_ref.dart';
import 'package:observatory/src/elements/containers/virtual_tree.dart';
import 'package:observatory/src/elements/curly_block.dart';
import 'package:observatory/src/elements/helpers/any_ref.dart';
import 'package:observatory/src/elements/helpers/nav_bar.dart';
import 'package:observatory/src/elements/helpers/nav_menu.dart';
import 'package:observatory/src/elements/helpers/rendering_scheduler.dart';
import 'package:observatory/src/elements/helpers/tag.dart';
import 'package:observatory/src/elements/helpers/uris.dart';
import 'package:observatory/src/elements/nav/isolate_menu.dart';
import 'package:observatory/src/elements/nav/notify.dart';
import 'package:observatory/src/elements/nav/refresh.dart';
import 'package:observatory/src/elements/nav/top_menu.dart';
import 'package:observatory/src/elements/nav/vm_menu.dart';
import 'package:observatory/src/elements/tree_map.dart';
import 'package:observatory/repositories.dart';
import 'package:observatory/utils.dart';

enum HeapSnapshotTreeMode {
  classesTable,
  classesTableDiff,
  classesTreeMap,
  classesTreeMapDiff,
  dominatorTree,
  dominatorTreeMap,
  mergedDominatorTree,
  mergedDominatorTreeDiff,
  mergedDominatorTreeMap,
  mergedDominatorTreeMapDiff,
  ownershipTable,
  ownershipTableDiff,
  ownershipTreeMap,
  ownershipTreeMapDiff,
  predecessors,
  process,
  processDiff,
  successors,
}

// Note the order of these lists is reflected in the UI, and the first option
// is the default.
const viewModes = [
  HeapSnapshotTreeMode.mergedDominatorTreeMap,
  HeapSnapshotTreeMode.mergedDominatorTree,
  HeapSnapshotTreeMode.dominatorTreeMap,
  HeapSnapshotTreeMode.dominatorTree,
  HeapSnapshotTreeMode.ownershipTreeMap,
  HeapSnapshotTreeMode.ownershipTable,
  HeapSnapshotTreeMode.classesTreeMap,
  HeapSnapshotTreeMode.classesTable,
  HeapSnapshotTreeMode.successors,
  HeapSnapshotTreeMode.predecessors,
  HeapSnapshotTreeMode.process,
];

const diffModes = [
  HeapSnapshotTreeMode.mergedDominatorTreeMapDiff,
  HeapSnapshotTreeMode.mergedDominatorTreeDiff,
  HeapSnapshotTreeMode.ownershipTreeMapDiff,
  HeapSnapshotTreeMode.ownershipTableDiff,
  HeapSnapshotTreeMode.classesTreeMapDiff,
  HeapSnapshotTreeMode.classesTableDiff,
  HeapSnapshotTreeMode.processDiff,
];

abstract class NormalTreeMap<T> extends TreeMap<T> {
  int getSize(T node);
  String getName(T node);
  String getType(T node);

  int getArea(T node) => getSize(node);
  String getLabel(T node) {
    String name = getName(node);
    String size = Utils.formatSize(getSize(node));
    return "$name [$size]";
  }

  String getBackground(T node) {
    int hue = getType(node).hashCode % 360;
    return "hsl($hue,60%,60%)";
  }
}

abstract class DiffTreeMap<T> extends TreeMap<T> {
  int getSizeA(T node);
  int getSizeB(T node);

  // We need to sum gains and losses separately because they both contribute
  // area to the tree map tiles, i.e., losses don't have negative area in the
  // visualization. For this reason, common is not necessarily
  // max(sizeA,sizeB)-min(sizeA,sizeB), gain is not necessarily
  // abs(sizeB-sizeA), etc.
  int getGain(T node);
  int getLoss(T node);
  int getCommon(T node);

  String getName(T node);
  String getType(T node);

  int getArea(T node) => getCommon(node) + getGain(node) + getLoss(node);
  String getLabel(T node) {
    var name = getName(node);
    var sizeA = Utils.formatSize(getSizeA(node));
    var sizeB = Utils.formatSize(getSizeB(node));
    return "$name [$sizeA → $sizeB]";
  }

  String getBackground(T node) {
    int l = getLoss(node);
    int c = getCommon(node);
    int g = getGain(node);
    int a = l + c + g;
    if (a == 0) {
      return "white";
    }
    // Stripes of green, white and red whose areas are poritional to loss, common and gain.
    String stop1 = (l / a * 100).toString();
    String stop2 = ((l + c) / a * 100).toString();
    return "linear-gradient(to right, #66FF99 $stop1%, white $stop1% $stop2%, #FF6680 $stop2%)";
  }
}

class DominatorTreeMap extends NormalTreeMap<SnapshotObject> {
  HeapSnapshotElement element;
  DominatorTreeMap(this.element);

  int getSize(SnapshotObject node) => node.retainedSize;
  String getType(SnapshotObject node) => node.klass.name;
  String getName(SnapshotObject node) => node.description;
  SnapshotObject getParent(SnapshotObject node) => node.parent;
  Iterable<SnapshotObject> getChildren(SnapshotObject node) => node.children;
  void onSelect(SnapshotObject node) {
    element.selection = node.objects;
    element._r.dirty();
  }

  void onDetails(SnapshotObject node) {
    element.selection = node.objects;
    element._mode = HeapSnapshotTreeMode.successors;
    element._r.dirty();
  }
}

class MergedDominatorTreeMap
    extends NormalTreeMap<M.HeapSnapshotMergedDominatorNode> {
  HeapSnapshotElement element;
  MergedDominatorTreeMap(this.element);

  int getSize(M.HeapSnapshotMergedDominatorNode node) => node.retainedSize;
  String getType(M.HeapSnapshotMergedDominatorNode node) => node.klass.name;
  String getName(M.HeapSnapshotMergedDominatorNode node) =>
      (node as dynamic).description;
  M.HeapSnapshotMergedDominatorNode getParent(
          M.HeapSnapshotMergedDominatorNode node) =>
      (node as dynamic).parent;
  Iterable<M.HeapSnapshotMergedDominatorNode> getChildren(
          M.HeapSnapshotMergedDominatorNode node) =>
      node.children;
  void onSelect(M.HeapSnapshotMergedDominatorNode node) {
    element.mergedSelection = node;
    element._r.dirty();
  }

  void onDetails(M.HeapSnapshotMergedDominatorNode node) {
    dynamic n = node;
    element.selection = n.objects;
    element._mode = HeapSnapshotTreeMode.successors;
    element._r.dirty();
  }
}

class MergedDominatorDiffTreeMap extends DiffTreeMap<MergedDominatorDiff> {
  HeapSnapshotElement element;
  MergedDominatorDiffTreeMap(this.element);

  int getSizeA(MergedDominatorDiff node) => node.retainedSizeA;
  int getSizeB(MergedDominatorDiff node) => node.retainedSizeB;
  int getGain(MergedDominatorDiff node) => node.retainedGain;
  int getLoss(MergedDominatorDiff node) => node.retainedLoss;
  int getCommon(MergedDominatorDiff node) => node.retainedCommon;

  String getType(MergedDominatorDiff node) => node.name;
  String getName(MergedDominatorDiff node) => "instances of ${node.name}";
  MergedDominatorDiff getParent(MergedDominatorDiff node) => node.parent;
  Iterable<MergedDominatorDiff> getChildren(MergedDominatorDiff node) =>
      node.children;
  void onSelect(MergedDominatorDiff node) {
    element.mergedDiffSelection = node;
    element._r.dirty();
  }

  void onDetails(MergedDominatorDiff node) {
    element._snapshotA = element._snapshotB;
    element.selection = node.objectsB;
    element._mode = HeapSnapshotTreeMode.successors;
    element._r.dirty();
  }
}

// Using `null` to represent the root.
class ClassesShallowTreeMap extends NormalTreeMap<SnapshotClass> {
  HeapSnapshotElement element;
  M.HeapSnapshot snapshot;

  ClassesShallowTreeMap(this.element, this.snapshot);

  int getSize(SnapshotClass node) =>
      node == null ? snapshot.size : node.shallowSize;
  String getType(SnapshotClass node) => node == null ? "Classes" : node.name;
  String getName(SnapshotClass node) => node == null
      ? "${snapshot.classes.length} classes"
      : "${node.instanceCount} instances of ${node.name}";

  SnapshotClass getParent(SnapshotClass node) => null;
  Iterable<SnapshotClass> getChildren(SnapshotClass node) =>
      node == null ? snapshot.classes : <SnapshotClass>[];
  void onSelect(SnapshotClass node) {}
  void onDetails(SnapshotClass node) {
    element.selection = node.instances.toList();
    element._mode = HeapSnapshotTreeMode.successors;
    element._r.dirty();
  }
}

// Using `null` to represent the root.
class ClassesShallowDiffTreeMap extends DiffTreeMap<SnapshotClassDiff> {
  HeapSnapshotElement element;
  List<SnapshotClassDiff> classes;

  ClassesShallowDiffTreeMap(this.element, this.classes);

  int getSizeA(SnapshotClassDiff node) {
    if (node != null) return node.shallowSizeA;
    int s = 0;
    for (var cls in classes) s += cls.shallowSizeA;
    return s;
  }

  int getSizeB(SnapshotClassDiff node) {
    if (node != null) return node.shallowSizeB;
    int s = 0;
    for (var cls in classes) s += cls.shallowSizeB;
    return s;
  }

  int getGain(SnapshotClassDiff node) {
    if (node != null) return node.shallowSizeGain;
    int s = 0;
    for (var cls in classes) s += cls.shallowSizeGain;
    return s;
  }

  int getLoss(SnapshotClassDiff node) {
    if (node != null) return node.shallowSizeLoss;
    int s = 0;
    for (var cls in classes) s += cls.shallowSizeLoss;
    return s;
  }

  int getCommon(SnapshotClassDiff node) {
    if (node != null) return node.shallowSizeCommon;
    int s = 0;
    for (var cls in classes) s += cls.shallowSizeCommon;
    return s;
  }

  String getType(SnapshotClassDiff node) =>
      node == null ? "Classes" : node.name;
  String getName(SnapshotClassDiff node) =>
      node == null ? "${classes.length} classes" : "instances of ${node.name}";
  SnapshotClassDiff getParent(SnapshotClassDiff node) => null;
  Iterable<SnapshotClassDiff> getChildren(SnapshotClassDiff node) =>
      node == null ? classes : <SnapshotClassDiff>[];
  void onSelect(SnapshotClassDiff node) {}
  void onDetails(SnapshotClassDiff node) {
    element._snapshotA = element._snapshotB;
    element.selection = node.objectsB;
    element._mode = HeapSnapshotTreeMode.successors;
    element._r.dirty();
  }
}

// Using `null` to represent the root.
class ClassesOwnershipTreeMap extends NormalTreeMap<SnapshotClass> {
  HeapSnapshotElement element;
  M.HeapSnapshot snapshot;

  ClassesOwnershipTreeMap(this.element, this.snapshot);

  int getSize(SnapshotClass node) =>
      node == null ? snapshot.size : node.ownedSize;
  String getType(SnapshotClass node) => node == null ? "classes" : node.name;
  String getName(SnapshotClass node) => node == null
      ? "${snapshot.classes.length} Classes"
      : "${node.instanceCount} instances of ${node.name}";
  SnapshotClass getParent(SnapshotClass node) => null;
  Iterable<SnapshotClass> getChildren(SnapshotClass node) =>
      node == null ? snapshot.classes : <SnapshotClass>[];
  void onSelect(SnapshotClass node) {}
  void onDetails(SnapshotClass node) {
    element.selection = node.instances.toList();
    element._mode = HeapSnapshotTreeMode.successors;
    element._r.dirty();
  }
}

// Using `null` to represent the root.
class ClassesOwnershipDiffTreeMap extends DiffTreeMap<SnapshotClassDiff> {
  HeapSnapshotElement element;
  List<SnapshotClassDiff> classes;

  ClassesOwnershipDiffTreeMap(this.element, this.classes);

  int getSizeA(SnapshotClassDiff node) {
    if (node != null) return node.ownedSizeA;
    int s = 0;
    for (var cls in classes) s += cls.ownedSizeA;
    return s;
  }

  int getSizeB(SnapshotClassDiff node) {
    if (node != null) return node.ownedSizeB;
    int s = 0;
    for (var cls in classes) s += cls.ownedSizeB;
    return s;
  }

  int getGain(SnapshotClassDiff node) {
    if (node != null) return node.ownedSizeGain;
    int s = 0;
    for (var cls in classes) s += cls.ownedSizeGain;
    return s;
  }

  int getLoss(SnapshotClassDiff node) {
    if (node != null) return node.ownedSizeLoss;
    int s = 0;
    for (var cls in classes) s += cls.ownedSizeLoss;
    return s;
  }

  int getCommon(SnapshotClassDiff node) {
    if (node != null) return node.ownedSizeCommon;
    int s = 0;
    for (var cls in classes) s += cls.ownedSizeCommon;
    return s;
  }

  String getType(SnapshotClassDiff node) =>
      node == null ? "Classes" : node.name;
  String getName(SnapshotClassDiff node) =>
      node == null ? "${classes.length} classes" : "instances of ${node.name}";
  SnapshotClassDiff getParent(SnapshotClassDiff node) => null;
  Iterable<SnapshotClassDiff> getChildren(SnapshotClassDiff node) =>
      node == null ? classes : <SnapshotClassDiff>[];
  void onSelect(SnapshotClassDiff node) {}
  void onDetails(SnapshotClassDiff node) {
    element._snapshotA = element._snapshotB;
    element.selection = node.objectsB;
    element._mode = HeapSnapshotTreeMode.successors;
    element._r.dirty();
  }
}

class ProcessTreeMap extends NormalTreeMap<String> {
  static const String root = "RSS";
  HeapSnapshotElement element;
  M.HeapSnapshot snapshot;

  ProcessTreeMap(this.element, this.snapshot);

  int getSize(String node) => snapshot.processPartitions[node];
  String getType(String node) => node;
  String getName(String node) => node;
  String getParent(String node) => node == root ? null : root;
  Iterable<String> getChildren(String node) {
    if (node == root) {
      var children = snapshot.processPartitions.keys.toList();
      children.remove(root);
      return children;
    }
    return <String>[];
  }

  void onSelect(String node) {}
  void onDetails(String node) {}
}

class ProcessDiffTreeMap extends DiffTreeMap<PartitionDiff> {
  HeapSnapshotElement element;

  ProcessDiffTreeMap(this.element);

  int getSizeA(PartitionDiff node) => node.sizeA;
  int getSizeB(PartitionDiff node) => node.sizeB;
  int getGain(PartitionDiff node) => node.sizeGain;
  int getLoss(PartitionDiff node) => node.sizeLoss;
  int getCommon(PartitionDiff node) => node.sizeCommon;
  String getType(PartitionDiff node) => node.name;
  String getName(PartitionDiff node) => node.name;
  PartitionDiff getParent(PartitionDiff node) => node.parent;
  Iterable<PartitionDiff> getChildren(PartitionDiff node) => node.children;
  void onSelect(PartitionDiff node) {}
  void onDetails(PartitionDiff node) {}
}

class PartitionDiff {
  String name;
  int sizeA = 0;
  int sizeB = 0;
  int sizeGain = -1;
  int sizeLoss = -1;
  int sizeCommon = -1;

  PartitionDiff parent;
  List<PartitionDiff> children;

  static PartitionDiff from(SnapshotGraph graphA, SnapshotGraph graphB) {
    var partitions = new Set<String>();
    partitions.addAll(graphA.processPartitions.keys);
    partitions.addAll(graphB.processPartitions.keys);

    var root = ProcessTreeMap.root;
    var rootDiff = new PartitionDiff();
    rootDiff.name = root;
    rootDiff.sizeA = graphA.processPartitions[root] ?? 0;
    rootDiff.sizeB = graphB.processPartitions[root] ?? 0;
    rootDiff.children = new List<PartitionDiff>();
    partitions.remove(root);

    var childrenA = 0;
    var childrenB = 0;
    for (var partition in partitions) {
      var partitionDiff = new PartitionDiff();
      partitionDiff.name = partition;
      partitionDiff.sizeA = graphA.processPartitions[partition] ?? 0;
      partitionDiff.sizeB = graphB.processPartitions[partition] ?? 0;
      partitionDiff.parent = rootDiff;
      partitionDiff.children = const <PartitionDiff>[];
      if (partitionDiff.sizeB > partitionDiff.sizeA) {
        partitionDiff.sizeGain = partitionDiff.sizeB - partitionDiff.sizeA;
        partitionDiff.sizeCommon = partitionDiff.sizeA;
        partitionDiff.sizeLoss = 0;
      } else {
        partitionDiff.sizeGain = 0;
        partitionDiff.sizeCommon = partitionDiff.sizeB;
        partitionDiff.sizeLoss = partitionDiff.sizeA - partitionDiff.sizeB;
      }
      childrenA += partitionDiff.sizeA;
      childrenB += partitionDiff.sizeB;
      rootDiff.sizeGain += partitionDiff.sizeGain;
      rootDiff.sizeCommon += partitionDiff.sizeCommon;
      rootDiff.sizeLoss += partitionDiff.sizeLoss;
      rootDiff.children.add(partitionDiff);
    }

    var shallowA = rootDiff.sizeA - childrenA;
    var shallowB = rootDiff.sizeB - childrenB;
    if (shallowB > shallowA) {
      rootDiff.sizeGain += shallowB - shallowA;
      rootDiff.sizeCommon += shallowA;
      rootDiff.sizeLoss += 0;
    } else {
      rootDiff.sizeGain += 0;
      rootDiff.sizeCommon += shallowB;
      rootDiff.sizeLoss += shallowA - shallowB;
    }

    return rootDiff;
  }
}

class SnapshotClassDiff {
  SnapshotClass _a;
  SnapshotClass _b;

  int get shallowSizeA => _a == null ? 0 : _a.shallowSize;
  int get ownedSizeA => _a == null ? 0 : _a.ownedSize;
  int get instanceCountA => _a == null ? 0 : _a.instanceCount;

  int get shallowSizeB => _b == null ? 0 : _b.shallowSize;
  int get ownedSizeB => _b == null ? 0 : _b.ownedSize;
  int get instanceCountB => _b == null ? 0 : _b.instanceCount;

  int get shallowSizeDiff => shallowSizeB - shallowSizeA;
  int get ownedSizeDiff => ownedSizeB - ownedSizeA;
  int get instanceCountDiff => instanceCountB - instanceCountA;

  int get shallowSizeGain =>
      shallowSizeB > shallowSizeA ? shallowSizeB - shallowSizeA : 0;
  int get ownedSizeGain =>
      ownedSizeB > ownedSizeA ? ownedSizeB - ownedSizeA : 0;
  int get shallowSizeLoss =>
      shallowSizeA > shallowSizeB ? shallowSizeA - shallowSizeB : 0;
  int get ownedSizeLoss =>
      ownedSizeA > ownedSizeB ? ownedSizeA - ownedSizeB : 0;
  int get shallowSizeCommon =>
      shallowSizeB > shallowSizeA ? shallowSizeA : shallowSizeB;
  int get ownedSizeCommon => ownedSizeB > ownedSizeA ? ownedSizeA : ownedSizeB;

  String get name => _a == null ? _b.name : _a.name;

  List<SnapshotObject> get objectsA =>
      _a == null ? <SnapshotObject>[] : _a.instances;
  List<SnapshotObject> get objectsB =>
      _b == null ? <SnapshotObject>[] : _b.instances;

  static List<SnapshotClassDiff> from(
      SnapshotGraph graphA, SnapshotGraph graphB) {
    // Matching classes by SnapshotClass.qualifiedName.
    var classesB = new Map<String, SnapshotClass>();
    var classesDiff = new List<SnapshotClassDiff>();
    for (var classB in graphB.classes) {
      classesB[classB.qualifiedName] = classB;
    }
    for (var classA in graphA.classes) {
      var classDiff = new SnapshotClassDiff();
      var qualifiedName = classA.qualifiedName;
      var name = classA.name;
      classDiff._a = classA;
      var classB = classesB[qualifiedName];
      if (classB != null) {
        classesB.remove(qualifiedName);
        classDiff._b = classB;
      }
      classesDiff.add(classDiff);
    }
    for (var classB in classesB.values) {
      var classDiff = new SnapshotClassDiff();
      classDiff._b = classB;
      classesDiff.add(classDiff);
    }
    return classesDiff;
  }
}

class MergedDominatorDiff {
  MergedObjectVertex _a;
  MergedObjectVertex _b;
  MergedDominatorDiff parent;
  List<MergedDominatorDiff> children;
  int retainedGain = -1;
  int retainedLoss = -1;
  int retainedCommon = -1;

  int get shallowSizeA => _a == null ? 0 : _a.shallowSize;
  int get retainedSizeA => _a == null ? 0 : _a.retainedSize;
  int get instanceCountA => _a == null ? 0 : _a.instanceCount;

  int get shallowSizeB => _b == null ? 0 : _b.shallowSize;
  int get retainedSizeB => _b == null ? 0 : _b.retainedSize;
  int get instanceCountB => _b == null ? 0 : _b.instanceCount;

  int get shallowSizeDiff => shallowSizeB - shallowSizeA;
  int get retainedSizeDiff => retainedSizeB - retainedSizeA;
  int get instanceCountDiff => instanceCountB - instanceCountA;

  String get name => _a == null ? _b.klass.name : _a.klass.name;

  List<SnapshotObject> get objectsA =>
      _a == null ? <SnapshotObject>[] : _a.objects;
  List<SnapshotObject> get objectsB =>
      _b == null ? <SnapshotObject>[] : _b.objects;

  static MergedDominatorDiff from(MergedObjectVertex a, MergedObjectVertex b) {
    var root = new MergedDominatorDiff();
    root._a = a;
    root._b = b;

    // We must use an explicit stack instead of the call stack because the
    // dominator tree can be arbitrarily deep. We need to compute the full
    // tree to compute areas, so we do this eagerly to avoid having to
    // repeatedly test for initialization.
    var worklist = new List<MergedDominatorDiff>();
    worklist.add(root);
    // Compute children top-down.
    for (var i = 0; i < worklist.length; i++) {
      worklist[i]._computeChildren(worklist);
    }
    // Compute area botton-up.
    for (var i = worklist.length - 1; i >= 0; i--) {
      worklist[i]._computeArea();
    }

    return root;
  }

  void _computeChildren(List<MergedDominatorDiff> worklist) {
    assert(children == null);
    children = new List<MergedDominatorDiff>();

    // Matching children by MergedObjectVertex.klass.qualifiedName.
    var childrenB = new Map<String, MergedObjectVertex>();
    if (_b != null)
      for (var childB in _b.dominatorTreeChildren()) {
        childrenB[childB.klass.qualifiedName] = childB;
      }
    if (_a != null)
      for (var childA in _a.dominatorTreeChildren()) {
        var childDiff = new MergedDominatorDiff();
        childDiff.parent = this;
        childDiff._a = childA;
        var qualifiedName = childA.klass.qualifiedName;
        var childB = childrenB[qualifiedName];
        if (childB != null) {
          childrenB.remove(qualifiedName);
          childDiff._b = childB;
        }
        children.add(childDiff);
        worklist.add(childDiff);
      }
    for (var childB in childrenB.values) {
      var childDiff = new MergedDominatorDiff();
      childDiff.parent = this;
      childDiff._b = childB;
      children.add(childDiff);
      worklist.add(childDiff);
    }

    if (children.length == 0) {
      // Compress.
      children = const <MergedDominatorDiff>[];
    }
  }

  void _computeArea() {
    int g = 0;
    int l = 0;
    int c = 0;
    for (var child in children) {
      g += child.retainedGain;
      l += child.retainedLoss;
      c += child.retainedCommon;
    }
    int d = shallowSizeDiff;
    if (d > 0) {
      g += d;
      c += shallowSizeA;
    } else {
      l -= d;
      c += shallowSizeB;
    }
    assert(retainedSizeA + g - l == retainedSizeB);
    retainedGain = g;
    retainedLoss = l;
    retainedCommon = c;
  }
}

class HeapSnapshotElement extends CustomElement implements Renderable {
  static const tag =
      const Tag<HeapSnapshotElement>('heap-snapshot', dependencies: const [
    ClassRefElement.tag,
    NavTopMenuElement.tag,
    NavVMMenuElement.tag,
    NavIsolateMenuElement.tag,
    NavRefreshElement.tag,
    NavNotifyElement.tag,
    VirtualTreeElement.tag,
  ]);

  RenderingScheduler<HeapSnapshotElement> _r;

  Stream<RenderedEvent<HeapSnapshotElement>> get onRendered => _r.onRendered;

  M.VM _vm;
  M.IsolateRef _isolate;
  M.EventRepository _events;
  M.NotificationRepository _notifications;
  M.HeapSnapshotRepository _snapshots;
  M.ObjectRepository _objects;
  List<M.HeapSnapshot> _loadedSnapshots = new List<M.HeapSnapshot>();
  M.HeapSnapshot _snapshotA;
  M.HeapSnapshot _snapshotB;
  Stream<M.HeapSnapshotLoadingProgressEvent> _progressStream;
  M.HeapSnapshotLoadingProgress _progress;
  HeapSnapshotTreeMode _mode = HeapSnapshotTreeMode.mergedDominatorTreeMap;

  M.IsolateRef get isolate => _isolate;
  M.NotificationRepository get notifications => _notifications;
  M.HeapSnapshotRepository get profiles => _snapshots;
  M.VMRef get vm => _vm;

  List<SnapshotObject> selection;
  M.HeapSnapshotMergedDominatorNode mergedSelection;
  MergedDominatorDiff mergedDiffSelection;

  factory HeapSnapshotElement(
      M.VM vm,
      M.IsolateRef isolate,
      M.EventRepository events,
      M.NotificationRepository notifications,
      M.HeapSnapshotRepository snapshots,
      M.ObjectRepository objects,
      {RenderingQueue queue}) {
    assert(vm != null);
    assert(isolate != null);
    assert(events != null);
    assert(notifications != null);
    assert(snapshots != null);
    assert(objects != null);
    HeapSnapshotElement e = new HeapSnapshotElement.created();
    e._r = new RenderingScheduler<HeapSnapshotElement>(e, queue: queue);
    e._vm = vm;
    e._isolate = isolate;
    e._events = events;
    e._notifications = notifications;
    e._snapshots = snapshots;
    e._objects = objects;
    return e;
  }

  HeapSnapshotElement.created() : super.created(tag);

  @override
  attached() {
    super.attached();
    _r.enable();
    _refresh();
  }

  @override
  detached() {
    super.detached();
    _r.disable(notify: true);
    children = <Element>[];
  }

  void render() {
    final content = <Element>[
      navBar(<Element>[
        new NavTopMenuElement(queue: _r.queue).element,
        new NavVMMenuElement(_vm, _events, queue: _r.queue).element,
        new NavIsolateMenuElement(_isolate, _events, queue: _r.queue).element,
        navMenu('heap snapshot'),
        (new NavRefreshElement(queue: _r.queue)
              ..disabled = M.isHeapSnapshotProgressRunning(_progress?.status)
              ..onRefresh.listen((e) {
                _refresh();
              }))
            .element,
        (new NavRefreshElement(label: 'save', queue: _r.queue)
              ..disabled = M.isHeapSnapshotProgressRunning(_progress?.status)
              ..onRefresh.listen((e) {
                _save();
              }))
            .element,
        (new NavRefreshElement(label: 'load', queue: _r.queue)
              ..disabled = M.isHeapSnapshotProgressRunning(_progress?.status)
              ..onRefresh.listen((e) {
                _load();
              }))
            .element,
        new NavNotifyElement(_notifications, queue: _r.queue).element
      ]),
    ];
    if (_progress == null) {
      children = content;
      return;
    }
    switch (_progress.status) {
      case M.HeapSnapshotLoadingStatus.fetching:
        content.addAll(_createStatusMessage('Fetching snapshot from VM...',
            description: _progress.stepDescription,
            progress: _progress.progress));
        break;
      case M.HeapSnapshotLoadingStatus.loading:
        content.addAll(_createStatusMessage('Loading snapshot...',
            description: _progress.stepDescription,
            progress: _progress.progress));
        break;
      case M.HeapSnapshotLoadingStatus.loaded:
        content.addAll(_createReport());
        break;
    }
    children = content;
  }

  _refresh() {
    _progress = null;
    _snapshotLoading(_snapshots.get(isolate));
  }

  _save() {
    var blob = new Blob([_snapshotA.encoded], 'application/octet-stream');
    var blobUrl = Url.createObjectUrl(blob);
    var link = new AnchorElement();
    link.href = blobUrl;
    var now = new DateTime.now();
    link.download = 'dart-heap-${now.year}-${now.month}-${now.day}.bin';
    link.click();
  }

  _load() {
    var input = new InputElement();
    input.type = 'file';
    input.multiple = false;
    input.onChange.listen((event) {
      var file = input.files[0];
      var reader = new FileReader();
      reader.onLoad.listen((event) async {
        Uint8List encoded = reader.result;
        _snapshotLoading(
            new HeapSnapshotLoadingProgress.fetched(_isolate, encoded)
                .onProgress);
      });
      reader.readAsArrayBuffer(file);
    });
    input.click();
  }

  _snapshotLoading(Stream<HeapSnapshotLoadingProgressEvent> s) async {
    _progress = null;
    _progressStream = s;
    _r.dirty();
    _progressStream.listen((e) {
      _progress = e.progress;
      _r.dirty();
    });
    _progress = (await _progressStream.first).progress;
    _r.dirty();
    if (M.isHeapSnapshotProgressRunning(_progress.status)) {
      _progress = (await _progressStream.last).progress;
      _snapshotLoaded(_progress.snapshot);
    }
  }

  _snapshotLoaded(M.HeapSnapshot snapshot) {
    _loadedSnapshots.add(snapshot);
    _snapshotA = snapshot;
    _snapshotB = snapshot;
    selection = null;
    mergedSelection = null;
    mergedDiffSelection = null;
    _r.dirty();
  }

  static List<Element> _createStatusMessage(String message,
      {String description: '', double progress: 0.0}) {
    return [
      new DivElement()
        ..classes = ['content-centered-big']
        ..children = <Element>[
          new DivElement()
            ..classes = ['statusBox', 'shadow', 'center']
            ..children = <Element>[
              new DivElement()
                ..classes = ['statusMessage']
                ..text = message,
              new DivElement()
                ..classes = ['statusDescription']
                ..text = description,
              new DivElement()
                ..style.background = '#0489c3'
                ..style.width = '$progress%'
                ..style.height = '15px'
                ..style.borderRadius = '4px'
            ]
        ]
    ];
  }

  VirtualTreeElement _tree;

  void _createTreeMap<T>(List<HtmlElement> report, TreeMap<T> treemap, T root) {
    final content = new DivElement();
    content.style.border = '1px solid black';
    content.style.width = '100%';
    content.style.height = '100%';
    content.text = 'Performing layout...';
    Timer.run(() {
      // Generate the treemap after the content div has been added to the
      // document so that we can ask the browser how much space is
      // available for treemap layout.
      treemap.showIn(root, content);
    });

    final text =
        'Double-click a tile to zoom in. Double-click the outermost tile to zoom out. Right-click a tile to inspect its objects.';
    report.addAll([
      new DivElement()
        ..classes = ['content-centered-big', 'explanation']
        ..text = text,
      new DivElement()
        ..classes = ['content-centered-big']
        ..style.width = '100%'
        ..style.height = '100%'
        ..children = [content]
    ]);
  }

  List<Element> _createReport() {
    var report = <HtmlElement>[
      new DivElement()
        ..classes = ['content-centered-big']
        ..children = <Element>[
          new DivElement()
            ..classes = ['memberList']
            ..children = <Element>[
              new DivElement()
                ..classes = ['memberItem']
                ..children = <Element>[
                  new DivElement()
                    ..classes = ['memberName']
                    ..text = 'Snapshot A',
                  new DivElement()
                    ..classes = ['memberName']
                    ..children = _createSnapshotSelectA()
                ],
              new DivElement()
                ..classes = ['memberItem']
                ..children = <Element>[
                  new DivElement()
                    ..classes = ['memberName']
                    ..text = 'Snapshot B',
                  new DivElement()
                    ..classes = ['memberName']
                    ..children = _createSnapshotSelectB()
                ],
              new DivElement()
                ..classes = ['memberItem']
                ..children = <Element>[
                  new DivElement()
                    ..classes = ['memberName']
                    ..text = (_snapshotA == _snapshotB) ? 'View ' : 'Compare ',
                  new DivElement()
                    ..classes = ['memberName']
                    ..children = _createModeSelect()
                ]
            ]
        ],
    ];
    switch (_mode) {
      case HeapSnapshotTreeMode.dominatorTree:
        if (selection == null) {
          selection = _snapshotA.root.objects;
        }
        _tree = new VirtualTreeElement(
            _createDominator, _updateDominator, _getChildrenDominator,
            items: selection, queue: _r.queue);
        if (selection.length == 1) {
          _tree.expand(selection.first);
        }
        final text = 'In a heap dominator tree, an object X is a parent of '
            'object Y if every path from the root to Y goes through '
            'X. This allows you to find "choke points" that are '
            'holding onto a lot of memory. If an object becomes '
            'garbage, all its children in the dominator tree become '
            'garbage as well.';
        report.addAll([
          new DivElement()
            ..classes = ['content-centered-big', 'explanation']
            ..text = text,
          _tree.element
        ]);
        break;
      case HeapSnapshotTreeMode.dominatorTreeMap:
        if (selection == null) {
          selection = _snapshotA.root.objects;
        }
        _createTreeMap(report, new DominatorTreeMap(this), selection.first);
        break;
      case HeapSnapshotTreeMode.mergedDominatorTree:
        _tree = new VirtualTreeElement(_createMergedDominator,
            _updateMergedDominator, _getChildrenMergedDominator,
            items: _getChildrenMergedDominator(_snapshotA.mergedDominatorTree),
            queue: _r.queue);
        _tree.expand(_snapshotA.mergedDominatorTree);
        final text = 'A heap dominator tree, where siblings with the same class'
            ' have been merged into a single node.';
        report.addAll([
          new DivElement()
            ..classes = ['content-centered-big', 'explanation']
            ..text = text,
          _tree.element
        ]);
        break;
      case HeapSnapshotTreeMode.mergedDominatorTreeDiff:
        var root = MergedDominatorDiff.from(
            (_snapshotA as dynamic).graph.mergedRoot,
            (_snapshotB as dynamic).graph.mergedRoot);
        _tree = new VirtualTreeElement(_createMergedDominatorDiff,
            _updateMergedDominatorDiff, _getChildrenMergedDominatorDiff,
            items: _getChildrenMergedDominatorDiff(root), queue: _r.queue);
        _tree.expand(root);
        final text = 'A heap dominator tree, where siblings with the same class'
            ' have been merged into a single node.';
        report.addAll([
          new DivElement()
            ..classes = ['content-centered-big', 'explanation']
            ..text = text,
          _tree.element
        ]);
        break;
      case HeapSnapshotTreeMode.mergedDominatorTreeMap:
        if (mergedSelection == null) {
          mergedSelection = _snapshotA.mergedDominatorTree;
        }
        _createTreeMap(
            report, new MergedDominatorTreeMap(this), mergedSelection);
        break;
      case HeapSnapshotTreeMode.mergedDominatorTreeMapDiff:
        if (mergedDiffSelection == null) {
          mergedDiffSelection = MergedDominatorDiff.from(
              (_snapshotA as dynamic).graph.mergedRoot,
              (_snapshotB as dynamic).graph.mergedRoot);
        }
        _createTreeMap(
            report, new MergedDominatorDiffTreeMap(this), mergedDiffSelection);
        break;
      case HeapSnapshotTreeMode.ownershipTable:
        final items = _snapshotA.classes.where((c) => c.ownedSize > 0).toList();
        items.sort((a, b) => b.ownedSize - a.ownedSize);
        _tree = new VirtualTreeElement(
            _createOwnership, _updateOwnership, _getChildrenOwnership,
            items: items, queue: _r.queue);
        _tree.expand(_snapshotA.root);
        final text = 'An object X is said to "own" object Y if X is the only '
            'object that references Y, or X owns the only object that '
            'references Y. In particular, objects "own" the space of any '
            'unshared lists or maps they reference.';
        report.addAll([
          new DivElement()
            ..classes = ['content-centered-big', 'explanation']
            ..text = text,
          _tree.element
        ]);
        break;
      case HeapSnapshotTreeMode.ownershipTableDiff:
        final items = SnapshotClassDiff.from(
            (_snapshotA as dynamic).graph, (_snapshotB as dynamic).graph);
        items.sort((a, b) => b.ownedSizeB - a.ownedSizeB);
        items.sort((a, b) => b.ownedSizeA - a.ownedSizeA);
        items.sort((a, b) => b.ownedSizeDiff - a.ownedSizeDiff);
        _tree = new VirtualTreeElement(_createOwnershipDiff,
            _updateOwnershipDiff, _getChildrenOwnershipDiff,
            items: items, queue: _r.queue);
        _tree.expand(_snapshotA.root);
        final text = 'An object X is said to "own" object Y if X is the only '
            'object that references Y, or X owns the only object that '
            'references Y. In particular, objects "own" the space of any '
            'unshared lists or maps they reference.';
        report.addAll([
          new DivElement()
            ..classes = ['content-centered-big', 'explanation']
            ..text = text,
          _tree.element
        ]);
        break;
      case HeapSnapshotTreeMode.ownershipTreeMap:
        _createTreeMap(
            report, new ClassesOwnershipTreeMap(this, _snapshotA), null);
        break;
      case HeapSnapshotTreeMode.ownershipTreeMapDiff:
        final items = SnapshotClassDiff.from(
            (_snapshotA as dynamic).graph, (_snapshotB as dynamic).graph);
        _createTreeMap(
            report, new ClassesOwnershipDiffTreeMap(this, items), null);
        break;
      case HeapSnapshotTreeMode.successors:
        if (selection == null) {
          selection = _snapshotA.root.objects;
        }
        _tree = new VirtualTreeElement(
            _createSuccessor, _updateSuccessor, _getChildrenSuccessor,
            items: selection, queue: _r.queue);
        if (selection.length == 1) {
          _tree.expand(selection.first);
        }
        final text = '';
        report.addAll([
          new DivElement()
            ..classes = ['content-centered-big', 'explanation']
            ..text = text,
          _tree.element
        ]);
        break;
      case HeapSnapshotTreeMode.predecessors:
        if (selection == null) {
          selection = _snapshotA.root.objects;
        }
        _tree = new VirtualTreeElement(
            _createPredecessor, _updatePredecessor, _getChildrenPredecessor,
            items: selection, queue: _r.queue);
        if (selection.length == 1) {
          _tree.expand(selection.first);
        }
        final text = '';
        report.addAll([
          new DivElement()
            ..classes = ['content-centered-big', 'explanation']
            ..text = text,
          _tree.element
        ]);
        break;
      case HeapSnapshotTreeMode.classesTable:
        final items = _snapshotA.classes.toList();
        items.sort((a, b) => b.shallowSize - a.shallowSize);
        _tree = new VirtualTreeElement(
            _createClass, _updateClass, _getChildrenClass,
            items: items, queue: _r.queue);
        report.add(_tree.element);
        break;
      case HeapSnapshotTreeMode.classesTableDiff:
        final items = SnapshotClassDiff.from(
            (_snapshotA as dynamic).graph, (_snapshotB as dynamic).graph);
        items.sort((a, b) => b.shallowSizeB - a.shallowSizeB);
        items.sort((a, b) => b.shallowSizeA - a.shallowSizeA);
        items.sort((a, b) => b.shallowSizeDiff - a.shallowSizeDiff);
        _tree = new VirtualTreeElement(
            _createClassDiff, _updateClassDiff, _getChildrenClassDiff,
            items: items, queue: _r.queue);
        report.add(_tree.element);
        break;
      case HeapSnapshotTreeMode.classesTreeMap:
        _createTreeMap(
            report, new ClassesShallowTreeMap(this, _snapshotA), null);
        break;

      case HeapSnapshotTreeMode.classesTreeMapDiff:
        final items = SnapshotClassDiff.from(
            (_snapshotA as dynamic).graph, (_snapshotB as dynamic).graph);
        _createTreeMap(
            report, new ClassesShallowDiffTreeMap(this, items), null);
        break;
      case HeapSnapshotTreeMode.process:
        _createTreeMap(
            report, new ProcessTreeMap(this, _snapshotA), ProcessTreeMap.root);
        break;
      case HeapSnapshotTreeMode.processDiff:
        final root = PartitionDiff.from(
            (_snapshotA as dynamic).graph, (_snapshotB as dynamic).graph);
        _createTreeMap(report, new ProcessDiffTreeMap(this), root);
        break;
      default:
        break;
    }
    return report;
  }

  static HtmlElement _createDominator(toggle) {
    return new DivElement()
      ..classes = ['tree-item']
      ..children = <Element>[
        new SpanElement()
          ..classes = ['percentage']
          ..title = 'percentage of heap being retained',
        new SpanElement()
          ..classes = ['size']
          ..title = 'retained size',
        new SpanElement()..classes = ['lines'],
        new ButtonElement()
          ..classes = ['expander']
          ..onClick.listen((_) => toggle(autoToggleSingleChildNodes: true)),
        new SpanElement()..classes = ['name'],
        new AnchorElement()
          ..classes = ['link']
          ..text = "[inspect]",
        new AnchorElement()
          ..classes = ['link']
          ..text = "[incoming]",
        new AnchorElement()
          ..classes = ['link']
          ..text = "[dominator-map]",
      ];
  }

  static HtmlElement _createSuccessor(toggle) {
    return new DivElement()
      ..classes = ['tree-item']
      ..children = <Element>[
        new SpanElement()..classes = ['lines'],
        new ButtonElement()
          ..classes = ['expander']
          ..onClick.listen((_) => toggle(autoToggleSingleChildNodes: true)),
        new SpanElement()
          ..classes = ['size']
          ..title = 'retained size',
        new SpanElement()
          ..classes = ['edge']
          ..title = 'name of outgoing field',
        new SpanElement()..classes = ['name'],
        new AnchorElement()
          ..classes = ['link']
          ..text = "[incoming]",
        new AnchorElement()
          ..classes = ['link']
          ..text = "[dominator-tree]",
        new AnchorElement()
          ..classes = ['link']
          ..text = "[dominator-map]",
      ];
  }

  static HtmlElement _createPredecessor(toggle) {
    return new DivElement()
      ..classes = ['tree-item']
      ..children = <Element>[
        new SpanElement()..classes = ['lines'],
        new ButtonElement()
          ..classes = ['expander']
          ..onClick.listen((_) => toggle(autoToggleSingleChildNodes: true)),
        new SpanElement()
          ..classes = ['size']
          ..title = 'retained size',
        new SpanElement()
          ..classes = ['edge']
          ..title = 'name of incoming field',
        new SpanElement()..classes = ['name'],
        new SpanElement()
          ..classes = ['link']
          ..text = "[inspect]",
        new AnchorElement()
          ..classes = ['link']
          ..text = "[dominator-tree]",
        new AnchorElement()
          ..classes = ['link']
          ..text = "[dominator-map]",
      ];
  }

  static HtmlElement _createMergedDominator(toggle) {
    return new DivElement()
      ..classes = ['tree-item']
      ..children = <Element>[
        new SpanElement()
          ..classes = ['percentage']
          ..title = 'percentage of heap being retained',
        new SpanElement()
          ..classes = ['size']
          ..title = 'retained size',
        new SpanElement()..classes = ['lines'],
        new ButtonElement()
          ..classes = ['expander']
          ..onClick.listen((_) => toggle(autoToggleSingleChildNodes: true)),
        new SpanElement()..classes = ['name']
      ];
  }

  static HtmlElement _createMergedDominatorDiff(toggle) {
    return new DivElement()
      ..classes = ['tree-item']
      ..children = <Element>[
        new SpanElement()
          ..classes = ['percentage']
          ..title = 'percentage of heap being retained',
        new SpanElement()
          ..classes = ['size']
          ..title = 'retained size A',
        new SpanElement()
          ..classes = ['percentage']
          ..title = 'percentage of heap being retained',
        new SpanElement()
          ..classes = ['size']
          ..title = 'retained size B',
        new SpanElement()
          ..classes = ['size']
          ..title = 'retained size change',
        new SpanElement()..classes = ['lines'],
        new ButtonElement()
          ..classes = ['expander']
          ..onClick.listen((_) => toggle(autoToggleSingleChildNodes: true)),
        new SpanElement()..classes = ['name']
      ];
  }

  static HtmlElement _createOwnership(toggle) {
    return new DivElement()
      ..classes = ['tree-item']
      ..children = <Element>[
        new SpanElement()
          ..classes = ['percentage']
          ..title = 'percentage of heap owned',
        new SpanElement()
          ..classes = ['size']
          ..title = 'owned size',
        new SpanElement()..classes = ['name']
      ];
  }

  static HtmlElement _createOwnershipDiff(toggle) {
    return new DivElement()
      ..classes = ['tree-item']
      ..children = <Element>[
        new SpanElement()
          ..classes = ['percentage']
          ..title = 'percentage of heap owned A',
        new SpanElement()
          ..classes = ['size']
          ..title = 'owned size A',
        new SpanElement()
          ..classes = ['percentage']
          ..title = 'percentage of heap owned B',
        new SpanElement()
          ..classes = ['size']
          ..title = 'owned size B',
        new SpanElement()
          ..classes = ['size']
          ..title = 'owned size change',
        new SpanElement()..classes = ['name']
      ];
  }

  static HtmlElement _createClass(toggle) {
    return new DivElement()
      ..classes = ['tree-item']
      ..children = <Element>[
        new SpanElement()
          ..classes = ['percentage']
          ..title = 'percentage of heap owned',
        new SpanElement()
          ..classes = ['size']
          ..title = 'shallow size',
        new SpanElement()
          ..classes = ['size']
          ..title = 'instance count',
        new SpanElement()..classes = ['name']
      ];
  }

  static HtmlElement _createClassDiff(toggle) {
    return new DivElement()
      ..classes = ['tree-item']
      ..children = <Element>[
        new SpanElement()
          ..classes = ['size']
          ..title = 'shallow size A',
        new SpanElement()
          ..classes = ['size']
          ..title = 'instance count A',
        new SpanElement()
          ..classes = ['size']
          ..title = 'shallow size B',
        new SpanElement()
          ..classes = ['size']
          ..title = 'instance count B',
        new SpanElement()
          ..classes = ['size']
          ..title = 'shallow size diff',
        new SpanElement()
          ..classes = ['size']
          ..title = 'instance count diff',
        new SpanElement()..classes = ['name']
      ];
  }

  static const int kMaxChildren = 100;
  static const int kMinRetainedSize = 4096;

  static Iterable _getChildrenDominator(nodeDynamic) {
    SnapshotObject node = nodeDynamic;
    final list = node.children.toList();
    list.sort((a, b) => b.retainedSize - a.retainedSize);
    return list
        .where((child) => child.retainedSize >= kMinRetainedSize)
        .take(kMaxChildren);
  }

  static Iterable _getChildrenSuccessor(nodeDynamic) {
    SnapshotObject node = nodeDynamic;
    final list = node.successors.toList();
    return list;
  }

  static Iterable _getChildrenPredecessor(nodeDynamic) {
    SnapshotObject node = nodeDynamic;
    final list = node.predecessors.toList();
    return list;
  }

  static Iterable _getChildrenMergedDominator(nodeDynamic) {
    M.HeapSnapshotMergedDominatorNode node = nodeDynamic;
    final list = node.children.toList();
    list.sort((a, b) => b.retainedSize - a.retainedSize);
    return list
        .where((child) => child.retainedSize >= kMinRetainedSize)
        .take(kMaxChildren);
  }

  static Iterable _getChildrenMergedDominatorDiff(nodeDynamic) {
    MergedDominatorDiff node = nodeDynamic;
    final list = node.children.toList();
    list.sort((a, b) => b.retainedSizeDiff - a.retainedSizeDiff);
    return list
        .where((child) =>
            child.retainedSizeA >= kMinRetainedSize ||
            child.retainedSizeB >= kMinRetainedSize)
        .take(kMaxChildren);
  }

  static Iterable _getChildrenOwnership(item) {
    return const [];
  }

  static Iterable _getChildrenOwnershipDiff(item) {
    return const [];
  }

  static Iterable _getChildrenClass(item) {
    return const [];
  }

  static Iterable _getChildrenClassDiff(item) {
    return const [];
  }

  void _updateDominator(HtmlElement element, nodeDynamic, int depth) {
    SnapshotObject node = nodeDynamic;
    element.children[0].text = Utils.formatPercentNormalized(
        node.retainedSize * 1.0 / _snapshotA.size);
    element.children[1].text = Utils.formatSize(node.retainedSize);
    _updateLines(element.children[2].children, depth);
    if (_getChildrenDominator(node).isNotEmpty) {
      element.children[3].text = _tree.isExpanded(node) ? '▼' : '►';
    } else {
      element.children[3].text = '';
    }
    element.children[4].text = node.description;
    element.children[5].onClick.listen((_) {
      selection = node.objects;
      _mode = HeapSnapshotTreeMode.successors;
      _r.dirty();
    });
    element.children[6].onClick.listen((_) {
      selection = node.objects;
      _mode = HeapSnapshotTreeMode.predecessors;
      _r.dirty();
    });
    element.children[7].onClick.listen((_) {
      selection = node.objects;
      _mode = HeapSnapshotTreeMode.dominatorTreeMap;
      _r.dirty();
    });
  }

  void _updateSuccessor(HtmlElement element, nodeDynamic, int depth) {
    SnapshotObject node = nodeDynamic;
    _updateLines(element.children[0].children, depth);
    if (_getChildrenSuccessor(node).isNotEmpty) {
      element.children[1].text = _tree.isExpanded(node) ? '▼' : '►';
    } else {
      element.children[1].text = '';
    }
    element.children[2].text = Utils.formatSize(node.retainedSize);
    element.children[3].text = node.label;
    element.children[4].text = node.description;
    element.children[5].onClick.listen((_) {
      selection = node.objects;
      _mode = HeapSnapshotTreeMode.predecessors;
      _r.dirty();
    });
    element.children[6].onClick.listen((_) {
      selection = node.objects;
      _mode = HeapSnapshotTreeMode.dominatorTree;
      _r.dirty();
    });
    element.children[7].onClick.listen((_) {
      selection = node.objects;
      _mode = HeapSnapshotTreeMode.dominatorTreeMap;
      _r.dirty();
    });
  }

  void _updatePredecessor(HtmlElement element, nodeDynamic, int depth) {
    SnapshotObject node = nodeDynamic;
    _updateLines(element.children[0].children, depth);
    if (_getChildrenSuccessor(node).isNotEmpty) {
      element.children[1].text = _tree.isExpanded(node) ? '▼' : '►';
    } else {
      element.children[1].text = '';
    }
    element.children[2].text = Utils.formatSize(node.retainedSize);
    element.children[3].text = node.label;
    element.children[4].text = node.description;
    element.children[5].onClick.listen((_) {
      selection = node.objects;
      _mode = HeapSnapshotTreeMode.successors;
      _r.dirty();
    });
    element.children[6].onClick.listen((_) {
      selection = node.objects;
      _mode = HeapSnapshotTreeMode.dominatorTree;
      _r.dirty();
    });
    element.children[7].onClick.listen((_) {
      selection = node.objects;
      _mode = HeapSnapshotTreeMode.dominatorTreeMap;
      _r.dirty();
    });
  }

  void _updateMergedDominator(HtmlElement element, nodeDynamic, int depth) {
    M.HeapSnapshotMergedDominatorNode node = nodeDynamic;
    element.children[0].text = Utils.formatPercentNormalized(
        node.retainedSize * 1.0 / _snapshotA.size);
    element.children[1].text = Utils.formatSize(node.retainedSize);
    _updateLines(element.children[2].children, depth);
    if (_getChildrenMergedDominator(node).isNotEmpty) {
      element.children[3].text = _tree.isExpanded(node) ? '▼' : '►';
    } else {
      element.children[3].text = '';
    }
    element.children[4]
      ..text = '${node.instanceCount} instances of ${node.klass.name}';
  }

  void _updateMergedDominatorDiff(HtmlElement element, nodeDynamic, int depth) {
    MergedDominatorDiff node = nodeDynamic;
    element.children[0].text = Utils.formatPercentNormalized(
        node.retainedSizeA * 1.0 / _snapshotA.size);
    element.children[1].text = Utils.formatSize(node.retainedSizeA);
    element.children[2].text = Utils.formatPercentNormalized(
        node.retainedSizeB * 1.0 / _snapshotB.size);
    element.children[3].text = Utils.formatSize(node.retainedSizeB);
    element.children[4].text = (node.retainedSizeDiff > 0 ? '+' : '') +
        Utils.formatSize(node.retainedSizeDiff);
    element.children[4].style.color =
        node.retainedSizeDiff > 0 ? "red" : "green";
    _updateLines(element.children[5].children, depth);
    if (_getChildrenMergedDominatorDiff(node).isNotEmpty) {
      element.children[6].text = _tree.isExpanded(node) ? '▼' : '►';
    } else {
      element.children[6].text = '';
    }
    element.children[7]
      ..text =
          '${node.instanceCountA} → ${node.instanceCountB} instances of ${node.name}';
  }

  void _updateOwnership(HtmlElement element, nodeDynamic, int depth) {
    SnapshotClass node = nodeDynamic;
    element.children[0].text =
        Utils.formatPercentNormalized(node.ownedSize * 1.0 / _snapshotA.size);
    element.children[1].text = Utils.formatSize(node.ownedSize);
    element.children[2].text = node.name;
  }

  void _updateOwnershipDiff(HtmlElement element, nodeDynamic, int depth) {
    SnapshotClassDiff node = nodeDynamic;
    element.children[0].text =
        Utils.formatPercentNormalized(node.ownedSizeA * 1.0 / _snapshotA.size);
    element.children[1].text = Utils.formatSize(node.ownedSizeA);
    element.children[2].text =
        Utils.formatPercentNormalized(node.ownedSizeB * 1.0 / _snapshotB.size);
    element.children[3].text = Utils.formatSize(node.ownedSizeB);
    element.children[4].text = (node.ownedSizeDiff > 0 ? "+" : "") +
        Utils.formatSize(node.ownedSizeDiff);
    element.children[4].style.color = node.ownedSizeDiff > 0 ? "red" : "green";
    element.children[5].text = node.name;
  }

  void _updateClass(HtmlElement element, nodeDynamic, int depth) {
    SnapshotClass node = nodeDynamic;
    element.children[0].text =
        Utils.formatPercentNormalized(node.shallowSize * 1.0 / _snapshotA.size);
    element.children[1].text = Utils.formatSize(node.shallowSize);
    element.children[2].text = node.instanceCount.toString();
    element.children[3].text = node.name;
  }

  void _updateClassDiff(HtmlElement element, nodeDynamic, int depth) {
    SnapshotClassDiff node = nodeDynamic;
    element.children[0].text = Utils.formatSize(node.shallowSizeA);
    element.children[1].text = node.instanceCountA.toString();
    element.children[2].text = Utils.formatSize(node.shallowSizeB);
    element.children[3].text = node.instanceCountB.toString();
    element.children[4].text = (node.shallowSizeDiff > 0 ? "+" : "") +
        Utils.formatSize(node.shallowSizeDiff);
    element.children[4].style.color =
        node.shallowSizeDiff > 0 ? "red" : "green";
    element.children[5].text = (node.instanceCountDiff > 0 ? "+" : "") +
        node.instanceCountDiff.toString();
    element.children[5].style.color =
        node.instanceCountDiff > 0 ? "red" : "green";
    element.children[6].text = node.name;
  }

  static _updateLines(List<Element> lines, int n) {
    n = Math.max(0, n);
    while (lines.length > n) {
      lines.removeLast();
    }
    while (lines.length < n) {
      lines.add(new SpanElement());
    }
  }

  static String modeToString(HeapSnapshotTreeMode mode) {
    switch (mode) {
      case HeapSnapshotTreeMode.dominatorTree:
        return 'Dominators (tree)';
      case HeapSnapshotTreeMode.dominatorTreeMap:
        return 'Dominators (treemap)';
      case HeapSnapshotTreeMode.mergedDominatorTree:
      case HeapSnapshotTreeMode.mergedDominatorTreeDiff:
        return 'Dominators (tree, siblings merged by class)';
      case HeapSnapshotTreeMode.mergedDominatorTreeMap:
      case HeapSnapshotTreeMode.mergedDominatorTreeMapDiff:
        return 'Dominators (treemap, siblings merged by class)';
      case HeapSnapshotTreeMode.ownershipTable:
      case HeapSnapshotTreeMode.ownershipTableDiff:
        return 'Ownership (table)';
      case HeapSnapshotTreeMode.ownershipTreeMap:
      case HeapSnapshotTreeMode.ownershipTreeMapDiff:
        return 'Ownership (treemap)';
      case HeapSnapshotTreeMode.classesTable:
      case HeapSnapshotTreeMode.classesTableDiff:
        return 'Classes (table)';
      case HeapSnapshotTreeMode.classesTreeMap:
      case HeapSnapshotTreeMode.classesTreeMapDiff:
        return 'Classes (treemap)';
      case HeapSnapshotTreeMode.successors:
        return 'Successors / outgoing references';
      case HeapSnapshotTreeMode.predecessors:
        return 'Predecessors / incoming references';
      case HeapSnapshotTreeMode.process:
      case HeapSnapshotTreeMode.processDiff:
        return 'Process memory usage';
    }
    throw new Exception('Unknown HeapSnapshotTreeMode: $mode');
  }

  List<Element> _createModeSelect() {
    var s;
    var modes = _snapshotA == _snapshotB ? viewModes : diffModes;
    if (!modes.contains(_mode)) {
      _mode = modes[0];
      _r.dirty();
    }
    return [
      s = new SelectElement()
        ..classes = ['analysis-select']
        ..value = modeToString(_mode)
        ..children = modes.map((mode) {
          return new OptionElement(
              value: modeToString(mode), selected: _mode == mode)
            ..text = modeToString(mode);
        }).toList(growable: false)
        ..onChange.listen((_) {
          _mode = modes[s.selectedIndex];
          _r.dirty();
        })
    ];
  }

  String snapshotToString(snapshot) {
    if (snapshot == null) return "None";
    return snapshot.description + " " + Utils.formatSize(snapshot.size);
  }

  List<Element> _createSnapshotSelectA() {
    var s;
    return [
      s = new SelectElement()
        ..classes = ['analysis-select']
        ..value = snapshotToString(_snapshotA)
        ..children = _loadedSnapshots.map((snapshot) {
          return new OptionElement(
              value: snapshotToString(snapshot),
              selected: _snapshotA == snapshot)
            ..text = snapshotToString(snapshot);
        }).toList(growable: false)
        ..onChange.listen((_) {
          _snapshotA = _loadedSnapshots[s.selectedIndex];
          selection = null;
          mergedSelection = null;
          mergedDiffSelection = null;
          _r.dirty();
        })
    ];
  }

  List<Element> _createSnapshotSelectB() {
    var s;
    return [
      s = new SelectElement()
        ..classes = ['analysis-select']
        ..value = snapshotToString(_snapshotB)
        ..children = _loadedSnapshots.map((snapshot) {
          return new OptionElement(
              value: snapshotToString(snapshot),
              selected: _snapshotB == snapshot)
            ..text = snapshotToString(snapshot);
        }).toList(growable: false)
        ..onChange.listen((_) {
          _snapshotB = _loadedSnapshots[s.selectedIndex];
          selection = null;
          mergedSelection = null;
          mergedDiffSelection = null;
          _r.dirty();
        })
    ];
  }
}
