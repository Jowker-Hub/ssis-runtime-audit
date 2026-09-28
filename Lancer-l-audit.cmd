@echo off
rem ===========================================================================
rem  SSIS Runtime Audit - lanceur
rem
rem  Double-cliquez sur ce fichier. Les prerequis sont verifies, puis la
rem  fenetre de selection s'ouvre.
rem
rem  POURQUOI CE FICHIER EXISTE
rem    Un .ps1 ne se lance pas d'un double-clic : Windows l'ouvre dans le bloc-
rem    notes. Le clic droit "Executer avec PowerShell" fonctionne, mais se
rem    heurte a la strategie d'execution du poste, qui bloque par defaut les
rem    scripts non signes - avec un message que rien ne permet de relier au
rem    probleme reel.
rem
rem    Ce lanceur contourne les deux : il appelle PowerShell explicitement, et
rem    n'assouplit la strategie que pour CE processus. Rien n'est modifie sur
rem    le poste, et aucun autre script n'en beneficie.
rem
rem  -STA est indispensable : la fenetre de selection est une fenetre Windows
rem  Forms, et Windows Forms exige un apartment a fil unique.
rem ===========================================================================

setlocal

powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0Lancer-l-audit.ps1"

echo.
pause

endlocal
