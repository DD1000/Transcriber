"""Create a silent 3-second test movie from the publisher's public demo image."""
import sys
import cv2

image = cv2.imread(sys.argv[1])
assert image is not None
height, width = image.shape[:2]
writer = cv2.VideoWriter(sys.argv[2], cv2.VideoWriter_fourcc(*"avc1"), 10, (width, height))
assert writer.isOpened()
for _ in range(30):
    writer.write(image)
writer.release()
