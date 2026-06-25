import 'package:flutter/material.dart';

/// Two-finger pinch detector that does NOT interfere with the child's scrolling.
/// It uses a raw [Listener] (which passes events through to the scroll view)
/// and only reports a scale once two fingers are down — so single-finger
/// scrolling keeps working normally.
class PinchDetector extends StatefulWidget {
  const PinchDetector({
    super.key,
    required this.child,
    required this.onStart,
    required this.onScale,
  });

  final Widget child;
  final VoidCallback onStart;
  final ValueChanged<double> onScale;

  @override
  State<PinchDetector> createState() => _PinchDetectorState();
}

class _PinchDetectorState extends State<PinchDetector> {
  final _pointers = <int, Offset>{};
  double? _baseDistance;

  double _distance() {
    final p = _pointers.values.toList();
    return (p[0] - p[1]).distance;
  }

  void _down(PointerDownEvent e) {
    _pointers[e.pointer] = e.position;
    if (_pointers.length == 2) {
      _baseDistance = _distance();
      widget.onStart();
    }
  }

  void _move(PointerMoveEvent e) {
    if (!_pointers.containsKey(e.pointer)) return;
    _pointers[e.pointer] = e.position;
    if (_pointers.length >= 2 && _baseDistance != null && _baseDistance! > 0) {
      widget.onScale(_distance() / _baseDistance!);
    }
  }

  void _end(int pointer) {
    _pointers.remove(pointer);
    if (_pointers.length < 2) _baseDistance = null;
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _down,
      onPointerMove: _move,
      onPointerUp: (e) => _end(e.pointer),
      onPointerCancel: (e) => _end(e.pointer),
      child: widget.child,
    );
  }
}
