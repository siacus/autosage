# AutoSage
Preliminary metadata suggestion for a given dataset.

Based on the LLAMA-2-7B and LLAMA-3.2-3B models fine-tuned on the entire Harvard Dataverse corpus.

The first model (LLAMA-2-7B)has been trained on 76,110 datasets up to June 2024, using title and description only to predict multiple subject categories. Model shows an accuracy of 94.6% (at least one subject category right). Details and reference to scripts in this paper [https://arxiv.org/abs/2411.00890](https://arxiv.org/abs/2411.00890).

The second model (LLAMA-3.2-3B) has been trained on a subset of a clean and balanced training set (data balanced by subject category). The model accuracy varies around 80%. A paper is still in the writing.


# Details
This repository contains just the Shiny R application. The app is deployed on a Mac. Further details will follow. The models are also open-sourced, soon on huggingface.

The app either loads Title and Description from an existing datasets in Dataverse through its DOI or accepts in input Title and Description. 

DOI metadata extraction works, with some heuristic, with these repositories:

- **Dataverse** (any installation in the global network)
- **Zenodo**
- **Figshare**
- **Dryad**
- **Mendeley**

although, at present, not all subject categories can be matched properly give the different schemas used by the different repositories.

The System is based on llama.cpp server offering the two models through API and a Shiny App.
Future plan is to improve APIs using an openAPI layer that talks to llama-server and provide the output in a canonical format.

The app will one day support export functionalities and more automatic metadata curation. Please open issues for feature requests.

# Requirements for this app
Install R

Install XQuart from: [https://www.xquartz.org](https://www.xquartz.org)

Install these packages in your R environment

`install.packages(c("shiny", "shinydashboard", "httr", "jsonlite", "stringr", "stringdist","shinyWidgets"))`

# Try it!
http://140.247.120.209:8083/

# Other sys-admin info [section to be completed]

## launch the app at reboot/startup/login
launchctl load ~/Library/LaunchAgents/com.service.shinySage.plist

## launch llama-server(s) at reboot/startup/login


