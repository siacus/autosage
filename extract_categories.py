import json
from datasets import load_dataset

# Load dataset
cap_dataset = "siacus/dv_subject"
dataset = load_dataset(cap_dataset, split={"train": "train", "test": "test"})

# Extract subject lists
subjects = dataset["train"]["Subject"]

# Get unique subject categories
def get_unique_categories(subject_lists):
    unique = set()
    for sublist in subject_lists:
        unique.update(sublist)
    return sorted(unique)

unique_categories = get_unique_categories(subjects)

# Save to JSON
with open("categories.json", "w") as f:
    json.dump(unique_categories, f, indent=2)

print(f"Saved {len(unique_categories)} unique subject categories to categories.json")
