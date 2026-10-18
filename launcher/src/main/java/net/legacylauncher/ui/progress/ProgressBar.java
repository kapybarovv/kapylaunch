package net.legacylauncher.ui.progress;

import net.legacylauncher.ui.LegacyLauncherFrame;
import net.legacylauncher.ui.theme.Theme;
import net.legacylauncher.util.StringUtil;
import net.legacylauncher.util.SwingUtil;

import javax.swing.*;
import java.awt.*;
import java.awt.event.ComponentEvent;
import java.awt.event.ComponentListener;
import java.awt.geom.RoundRectangle2D;
import java.util.Objects;

public class ProgressBar extends JProgressBar {
    private final Color textColor = Theme.getTheme().getForeground();
    public static final int DEFAULT_HEIGHT = SwingUtil.magnify(20);
    private static final int BORDER_SIZE = SwingUtil.magnify(10);
    private static final int EDGE_CHARS = 50;
    private static final int CENTER_CHARS = 30;
    private static final long serialVersionUID = -8095192709934629794L;
    private final Object sync;
    private final Component parent;
    private String wS;
    private String cS;
    private String eS;
    private boolean wS_changed;
    private boolean cS_changed;
    private boolean eS_changed;
    private int wS_x;
    private int cS_x;
    private int eS_x;
    private int oldWidth;
    private Timer glassTimer;
    private float glassOffset;

    public ProgressBar(Component parentComp) {
        sync = new Object();
        parent = parentComp;
        if (parent != null) {
            parent.addComponentListener(new ComponentListener() {
                public void componentResized(ComponentEvent e) {
                    updateSize();
                }

                public void componentMoved(ComponentEvent e) {
                }

                public void componentShown(ComponentEvent e) {
                }

                public void componentHidden(ComponentEvent e) {
                }
            });
        }
        setFont(getFont().deriveFont(LegacyLauncherFrame.getFontSize()));
        setOpaque(false);
        setBorderPainted(false);
        glassTimer = new Timer(32, event -> {
            glassOffset = glassOffset >= 1f ? 0f : glassOffset + .018f;
            repaint();
        });
        glassTimer.setCoalesce(true);
        glassTimer.setRepeats(true);
    }

    public ProgressBar() {
        this(null);
    }

    private void updateSize() {
        if (parent != null) {
            setPreferredSize(new Dimension(parent.getWidth(), DEFAULT_HEIGHT));
        }
    }

    public void setStrings(String west, String center, String east, boolean acceptNull, boolean repaint) {
        if (acceptNull || west != null) {
            setWestString(west, false);
        }

        if (acceptNull || center != null) {
            setCenterString(center, false);
        }

        if (acceptNull || east != null) {
            setEastString(east, false);
        }

        if (repaint) {
            repaint();
        }

    }

    public void setStrings(String west, String center, String east) {
        setStrings(west, center, east, true, true);
    }

    public void setWestString(String string, boolean update) {
        string = StringUtil.cut(string, EDGE_CHARS);
        wS_changed = !Objects.equals(wS, string);
        wS = string;
        if (wS_changed && update) {
            repaint();
        }

    }

    public void setWestString(String string) {
        setWestString(string, true);
    }

    public void setCenterString(String string, boolean update) {
        string = StringUtil.cut(string, CENTER_CHARS);
        cS_changed = string == null ? cS == null : !string.equals(cS);
        cS = string;
        if (cS_changed && update) {
            repaint();
        }

    }

    public void setCenterString(String string) {
        setCenterString(string, true);
    }

    public void setEastString(String string, boolean update) {
        string = StringUtil.cut(string, EDGE_CHARS);
        eS_changed = !Objects.equals(eS, string);
        eS = string;
        if (eS_changed && update) {
            repaint();
        }

    }

    public void setEastString(String string) {
        setEastString(string, true);
    }

    public void clearProgress() {
        setIndeterminate(false);
        setValue(0);
        setStrings(null, null, null, true, false);
    }

    public void startProgress() {
        clearProgress();
        updateSize();
        setVisible(true);
    }

    public void stopProgress() {
        setVisible(false);
        clearProgress();
    }

    private void draw(Graphics g) {
        boolean drawWest = wS != null;
        boolean drawCenter = cS != null;
        boolean drawEast = eS != null;
        if (drawWest || drawCenter || drawEast) {
            Font font = g.getFont();
            FontMetrics fm = g.getFontMetrics(font);
            int width = getWidth();
            boolean force = width != oldWidth;
            oldWidth = width;

            if (drawCenter && (force || cS_changed)) {
                cS_x = width / 2 - fm.stringWidth(cS) / 2;
                cS_changed = false;
            }

            if (drawWest && (force || wS_changed)) {
                wS_x = BORDER_SIZE;
                wS_changed = false;
            }

            if (drawEast && (force || eS_changed)) {
                eS_x = width - fm.stringWidth(eS) - BORDER_SIZE;
                eS_changed = false;
            }

            Graphics2D g2D = (Graphics2D) g;
            g2D.setRenderingHint(RenderingHints.KEY_TEXT_ANTIALIASING, RenderingHints.VALUE_TEXT_ANTIALIAS_ON);
            g.setFont(font);
            drawString(g, wS, wS_x);
            drawString(g, cS, cS_x);
            drawString(g, eS, eS_x);
        }
    }

    private void drawString(Graphics g, String s, int x) {
        if (s != null) {
            int y = (getHeight() - g.getFontMetrics().getDescent() + g.getFontMetrics().getAscent()) / 2;
            g.setColor(new Color(0, 14, 28, 142));
            g.drawString(s, x, y + 1);
            g.setColor(textColor);
            g.drawString(s, x, y);
        }
    }

    @Override
    protected void paintComponent(Graphics graphics) {
        Graphics2D g = (Graphics2D) graphics.create();
        try {
            g.setRenderingHint(RenderingHints.KEY_ANTIALIASING, RenderingHints.VALUE_ANTIALIAS_ON);
            g.setRenderingHint(RenderingHints.KEY_RENDERING, RenderingHints.VALUE_RENDER_QUALITY);

            int inset = Math.max(4, SwingUtil.magnify(5));
            int trackWidth = Math.max(0, getWidth() - inset * 2);
            int trackHeight = Math.max(7, Math.min(11, SwingUtil.magnify(9)));
            int trackY = (getHeight() - trackHeight) / 2;
            RoundRectangle2D track = new RoundRectangle2D.Float(inset, trackY, trackWidth, trackHeight,
                    trackHeight, trackHeight);

            g.setColor(new Color(235, 247, 255, 45));
            g.fill(track);
            g.setColor(new Color(255, 255, 255, 44));
            g.draw(track);

            if (trackWidth <= 0) {
                return;
            }

            int fillX = inset;
            int fillWidth;
            if (isIndeterminate()) {
                fillWidth = Math.max(trackHeight * 3, trackWidth / 3);
                fillX += Math.round((trackWidth - fillWidth) * glassOffset);
            } else {
                fillWidth = Math.round(trackWidth * (float) getPercentComplete());
            }

            if (fillWidth > 0) {
                RoundRectangle2D fill = new RoundRectangle2D.Float(fillX, trackY, fillWidth, trackHeight,
                        trackHeight, trackHeight);
                g.setPaint(new GradientPaint(0, trackY,
                        new Color(117, 218, 255, 230),
                        0, trackY + trackHeight,
                        new Color(40, 143, 233, 205)));
                g.fill(fill);

                Shape oldClip = g.getClip();
                g.clip(fill);
                g.setPaint(new GradientPaint(0, trackY,
                        new Color(255, 255, 255, 92),
                        0, trackY + trackHeight * .55f,
                        new Color(255, 255, 255, 0)));
                g.fillRect(fillX, trackY, fillWidth, Math.max(1, trackHeight / 2));
                g.setClip(oldClip);
            }
        } finally {
            g.dispose();
        }
    }

    @Override
    public void setIndeterminate(boolean indeterminate) {
        super.setIndeterminate(indeterminate);
        updateGlassTimer();
    }

    @Override
    public void setVisible(boolean visible) {
        super.setVisible(visible);
        updateGlassTimer();
    }

    private void updateGlassTimer() {
        if (glassTimer == null) {
            return;
        }
        if (isVisible() && isIndeterminate()) {
            if (!glassTimer.isRunning()) {
                glassTimer.start();
            }
        } else if (glassTimer.isRunning()) {
            glassTimer.stop();
        }
    }

    public void update(Graphics g) {
        try {
            super.update(g);
        } catch (Exception var4) {
            return;
        }

        Object e = sync;
        synchronized (sync) {
            draw(g);
        }
    }

    public void paint(Graphics g) {
        try {
            super.paint(g);
        } catch (Exception var4) {
            return;
        }

        Object e = sync;
        synchronized (sync) {
            draw(g);
        }
    }

    @Override
    public void updateUI() {
        Theme.setup(this);
        super.updateUI();
    }
}
