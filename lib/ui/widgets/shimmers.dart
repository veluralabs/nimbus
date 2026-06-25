import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';

/// Shared shimmer loading placeholders, used app-wide instead of spinners.

Shimmer _wrap(BuildContext context, Widget child) {
  final scheme = Theme.of(context).colorScheme;
  return Shimmer.fromColors(
    baseColor: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
    highlightColor: scheme.surfaceContainerHigh.withValues(alpha: 0.7),
    child: child,
  );
}

/// A single shimmering rounded box.
class ShimmerBox extends StatelessWidget {
  const ShimmerBox({super.key, this.height = 80, this.width, this.radius = 16});
  final double height;
  final double? width;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return _wrap(
      context,
      Container(
        height: height,
        width: width,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(radius),
        ),
      ),
    );
  }
}

/// A shimmering grid of tiles — stands in for the photo/asset grid while loading.
class ShimmerGrid extends StatelessWidget {
  const ShimmerGrid({super.key, this.tile = 120, this.count = 24});
  final double tile;
  final int count;

  @override
  Widget build(BuildContext context) {
    return _wrap(
      context,
      GridView.builder(
        padding: const EdgeInsets.all(8),
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: tile,
          mainAxisSpacing: 4,
          crossAxisSpacing: 4,
        ),
        itemCount: count,
        itemBuilder: (_, __) => Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
    );
  }
}

/// A shimmering list of cards — for Files / Settings-style lists.
class ShimmerList extends StatelessWidget {
  const ShimmerList({super.key, this.count = 6, this.height = 76});
  final int count;
  final double height;

  @override
  Widget build(BuildContext context) {
    return _wrap(
      context,
      ListView.separated(
        padding: const EdgeInsets.all(16),
        physics: const NeverScrollableScrollPhysics(),
        itemCount: count,
        separatorBuilder: (_, __) => const SizedBox(height: 12),
        itemBuilder: (_, __) => Container(
          height: height,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
          ),
        ),
      ),
    );
  }
}

/// Shimmering "people circles" for the People tab loading state.
class ShimmerPeople extends StatelessWidget {
  const ShimmerPeople({super.key, this.count = 9});
  final int count;

  @override
  Widget build(BuildContext context) {
    return _wrap(
      context,
      GridView.builder(
        padding: const EdgeInsets.all(16),
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 130,
          mainAxisSpacing: 16,
          crossAxisSpacing: 16,
          childAspectRatio: 0.8,
        ),
        itemCount: count,
        itemBuilder: (_, __) => Column(
          children: [
            Container(
              width: 88,
              height: 88,
              decoration: const BoxDecoration(
                  color: Colors.white, shape: BoxShape.circle),
            ),
            const SizedBox(height: 10),
            Container(width: 50, height: 10, color: Colors.white),
          ],
        ),
      ),
    );
  }
}
