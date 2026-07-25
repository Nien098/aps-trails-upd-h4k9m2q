import 'package:flutter/material.dart';

/// A lightweight filled line chart (e.g. elevation profile, pace over distance).
/// Takes raw (x, y) data and formatters for the axis labels. No dependencies.
class AreaLineChart extends StatelessWidget {
  const AreaLineChart({
    super.key,
    required this.data,
    required this.fmtY,
    required this.fmtX,
    this.color = const Color(0xFF1B5E20),
    this.height = 150,
    this.invertYBetter = false,
  });

  final List<Offset> data; // x = distance/time, y = value
  final String Function(double) fmtY;
  final String Function(double) fmtX;
  final Color color;
  final double height;

  /// If true, a lower y is "better" (pace) — only affects nothing visually here
  /// but kept for clarity at call sites.
  final bool invertYBetter;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(painter: _AreaLinePainter(data, fmtY, fmtX, color)),
    );
  }
}

class _AreaLinePainter extends CustomPainter {
  _AreaLinePainter(this.data, this.fmtY, this.fmtX, this.color);
  final List<Offset> data;
  final String Function(double) fmtY;
  final String Function(double) fmtX;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (data.length < 2) return;
    const padL = 44.0, padB = 20.0, padT = 8.0, padR = 8.0;
    final plot = Rect.fromLTRB(padL, padT, size.width - padR, size.height - padB);

    var minX = data.first.dx, maxX = data.first.dx;
    var minY = data.first.dy, maxY = data.first.dy;
    for (final o in data) {
      minX = o.dx < minX ? o.dx : minX;
      maxX = o.dx > maxX ? o.dx : maxX;
      minY = o.dy < minY ? o.dy : minY;
      maxY = o.dy > maxY ? o.dy : maxY;
    }
    if (maxX == minX) maxX = minX + 1;
    if (maxY == minY) maxY = minY + 1;
    // Pad the y-range a little so the line isn't glued to the edges.
    final yPad = (maxY - minY) * 0.12;
    minY -= yPad;
    maxY += yPad;

    double px(double x) =>
        plot.left + (x - minX) / (maxX - minX) * plot.width;
    double py(double y) =>
        plot.bottom - (y - minY) / (maxY - minY) * plot.height;

    final grid = Paint()
      ..color = Colors.black12
      ..strokeWidth = 1;
    final textStyle = const TextStyle(fontSize: 11, color: Color(0xFF6A6A6A));

    // Horizontal gridlines + y labels (min, mid, max).
    for (final f in [0.0, 0.5, 1.0]) {
      final yVal = minY + (maxY - minY) * f;
      final y = py(yVal);
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), grid);
      _label(canvas, fmtY(yVal), Offset(0, y - 7), textStyle, width: padL - 6,
          align: TextAlign.right);
    }

    // Area fill.
    final area = Path()..moveTo(px(data.first.dx), plot.bottom);
    for (final o in data) {
      area.lineTo(px(o.dx), py(o.dy));
    }
    area.lineTo(px(data.last.dx), plot.bottom);
    area.close();
    canvas.drawPath(area, Paint()..color = color.withValues(alpha: 0.18));

    // Line.
    final line = Path()..moveTo(px(data.first.dx), py(data.first.dy));
    for (final o in data.skip(1)) {
      line.lineTo(px(o.dx), py(o.dy));
    }
    canvas.drawPath(
        line,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5
          ..strokeJoin = StrokeJoin.round);

    // X labels at the ends.
    _label(canvas, fmtX(minX), Offset(plot.left, plot.bottom + 3), textStyle,
        width: 80, align: TextAlign.left);
    _label(canvas, fmtX(maxX), Offset(plot.right - 80, plot.bottom + 3),
        textStyle,
        width: 80, align: TextAlign.right);
  }

  void _label(Canvas canvas, String text, Offset at, TextStyle style,
      {required double width, required TextAlign align}) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textAlign: align,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: width);
    tp.paint(canvas, at);
  }

  @override
  bool shouldRepaint(covariant _AreaLinePainter old) => old.data != data;
}

/// A simple vertical bar chart (e.g. distance per week, split paces).
class BarChartMini extends StatelessWidget {
  const BarChartMini({
    super.key,
    required this.values,
    required this.labels,
    this.color = const Color(0xFF1B5E20),
    this.height = 150,
  });

  final List<double> values;
  final List<String> labels;
  final Color color;
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(painter: _BarPainter(values, labels, color)),
    );
  }
}

class _BarPainter extends CustomPainter {
  _BarPainter(this.values, this.labels, this.color);
  final List<double> values;
  final List<String> labels;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    const padB = 18.0, padT = 6.0;
    var maxV = 0.0;
    for (final v in values) {
      if (v > maxV) maxV = v;
    }
    if (maxV <= 0) maxV = 1;
    final plotH = size.height - padB - padT;
    final n = values.length;
    final slot = size.width / n;
    final barW = slot * 0.6;
    final paint = Paint()..color = color;
    final style = const TextStyle(fontSize: 10, color: Color(0xFF6A6A6A));
    for (var i = 0; i < n; i++) {
      final h = (values[i] / maxV) * plotH;
      final x = slot * i + (slot - barW) / 2;
      final rect = RRect.fromRectAndCorners(
        Rect.fromLTWH(x, padT + (plotH - h), barW, h),
        topLeft: const Radius.circular(3),
        topRight: const Radius.circular(3),
      );
      canvas.drawRRect(rect, paint);
      if (i < labels.length) {
        final tp = TextPainter(
          text: TextSpan(text: labels[i], style: style),
          textAlign: TextAlign.center,
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: slot);
        tp.paint(canvas, Offset(slot * i + (slot - tp.width) / 2,
            size.height - padB + 4));
      }
    }
  }

  @override
  bool shouldRepaint(covariant _BarPainter old) => old.values != values;
}
