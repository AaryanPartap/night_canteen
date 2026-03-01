import os
import re

# Define the folder to scan
folder_path = os.getcwd() # Assumes running from 'ios' folder

# Regex to find -G used as a flag (not part of -GCC or other words)
# Matches: " -G ", "-G0", or "-G" at start/end of quotes
regex_pattern = re.compile(r'(?<=\s)-G0?(?=\s)|(?<=")-G0?(?=\s)|(?<=\s)-G0?(?=")')

print(f"Scanning {folder_path} for bad '-G' flags...")

files_fixed = 0

for root, dirs, files in os.walk(folder_path):
    if "Pods.xcodeproj" in root or "Target Support Files" in root:
        for file in files:
            if file.endswith(".pbxproj") or file.endswith(".xcconfig"):
                file_path = os.path.join(root, file)

                try:
                    with open(file_path, 'r', encoding='utf-8', errors='ignore') as f:
                        content = f.read()

                    # Check if flag exists
                    if "-G " in content or "-G0" in content or '"-G"' in content:
                        # Replace standalone -G or -G0 with a space, preserving -GCC
                        new_content = regex_pattern.sub('', content)

                        # Extra safety check for strict "-G" edge cases
                        new_content = new_content.replace(' -G ', ' ')
                        new_content = new_content.replace('"-G ', '" ')
                        new_content = new_content.replace(' -G"', ' "')

                        if content != new_content:
                            with open(file_path, 'w', encoding='utf-8') as f:
                                f.write(new_content)
                            print(f"✅ Fixed: {file}")
                            files_fixed += 1
                except Exception as e:
                    print(f"Skipped {file}: {e}")

if files_fixed == 0:
    print("No files needed fixing. The flag might be hidden in derived data.")
else:
    print(f"🎉 Successfully removed -G flag from {files_fixed} files.")