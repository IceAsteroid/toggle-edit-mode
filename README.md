# toggle-edit
A read-only first workflow for buffer editing to prevent mistyping.

## Motivation
When I was using emacs on a laptop, I always had a bad habbit that mistyped something on a buffer that visited a file, which would cause a typo or change something critical without noticed.

So I created this mode for the ease of editing without the fear of accidentually changing something in a buffer.

## Usage

This mode enables read-only-mode when visiting a file, and a command can be bound to a key to toggle read-only-mode.

Also, when read-only-mode is on or off, cursor color will be changed,
  - when on, the color can be set to your preference with a custom variable.
  - when off, the color preserved from the theme cursor face will be set for the cursor.
